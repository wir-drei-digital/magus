defmodule Magus.Workspaces.WorkspaceDeletion do
  @moduledoc """
  Hard-delete a workspace and every resource scoped to it.

  Workspace resources (conversations, files, prompts, custom agents,
  knowledge sources, folders, brains, memories) are scoped to a workspace
  by `workspace_id` and are deleted with the workspace. There is no carry
  over to personal scope.

  `message_usages` rows survive: their `message_id` FK is set to NULL on
  message delete via the DB cascade, preserving aggregate billing /
  statistics. The user accounts themselves are untouched; only their
  membership in this workspace goes away.

  Pattern mirrors `Magus.Accounts.AccountDeletion`: external cleanup
  (S3, sandbox) runs OUTSIDE the DB transaction so multi-second network
  calls don't extend the transaction's lock window. The transaction-side
  step then re-runs cleanup as a no-op for the rows already gone (or
  finds none to delete).
  """
  require Ash.Query
  require Logger

  alias Magus.Workspaces.Workspace
  alias Magus.Workspaces.WorkspaceMember

  @type summary :: %{
          conversation_count: non_neg_integer(),
          file_count: non_neg_integer(),
          prompt_count: non_neg_integer(),
          custom_agent_count: non_neg_integer(),
          knowledge_source_count: non_neg_integer(),
          member_count: non_neg_integer()
        }

  @doc """
  Returns counts of what will be deleted, suitable for a confirmation modal.
  """
  @spec preflight(Workspace.t()) :: {:ok, summary()}
  def preflight(%Workspace{} = workspace) do
    {:ok,
     %{
       conversation_count: count_scoped(Magus.Chat.Conversation, workspace.id),
       file_count: count_scoped(Magus.Files.File, workspace.id),
       prompt_count: count_scoped(Magus.Library.Prompt, workspace.id),
       custom_agent_count: count_scoped(Magus.Agents.CustomAgent, workspace.id),
       knowledge_source_count: count_scoped(Magus.Knowledge.KnowledgeSource, workspace.id),
       member_count: count_active_members(workspace.id)
     }}
  end

  defp count_scoped(resource, workspace_id) do
    resource
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.count!(authorize?: false)
  rescue
    e in UndefinedFunctionError ->
      Logger.warning(
        "WorkspaceDeletion: count_scoped skipped for #{inspect(resource)}: #{Exception.message(e)}"
      )

      0
  end

  defp count_active_members(workspace_id) do
    WorkspaceMember
    |> Ash.Query.filter(workspace_id == ^workspace_id and is_active == true)
    |> Ash.count!(authorize?: false)
  end

  @doc """
  Hard-delete the workspace and all its child resources.

  The `actor` MUST be an active admin member of the workspace. The caller
  (typically the workspace settings LiveView) is also expected to gate on
  this, but the check is enforced again here for defense in depth.
  """
  @spec execute(Workspace.t(), keyword()) ::
          :ok | {:error, :not_authorized | term()}
  def execute(%Workspace{} = workspace, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    cond do
      not is_admin_member?(workspace.id, actor) ->
        {:error, :not_authorized}

      true ->
        broadcast_deactivated(workspace)
        cleanup_external_resources(workspace.id)
        delete_in_transaction(workspace)
    end
  end

  defp is_admin_member?(_workspace_id, nil), do: false

  defp is_admin_member?(workspace_id, %{id: user_id}) do
    WorkspaceMember
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and user_id == ^user_id and is_active == true and
        role == :admin
    )
    |> Ash.exists?(authorize?: false)
  end

  # Broadcast BEFORE we tear anything down so other connected sessions
  # leave the workspace cleanly via push_navigate. Reuses the existing
  # topic/event so the LiveView handler doesn't need to change.
  defp broadcast_deactivated(workspace) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "workspaces:#{workspace.id}",
      {:workspace_deactivated, workspace.id}
    )
  end

  # Best-effort cleanup of S3 / sandbox / other external systems for
  # workspace-scoped resources. Runs OUTSIDE the DB transaction so external
  # network calls (sandbox provider, S3) don't hold Postgres locks across
  # multi-second round trips. Failures are logged but do not block the
  # delete: orphan external blobs are far less bad than failing the whole
  # delete because an external service had a hiccup.
  defp cleanup_external_resources(workspace_id) do
    cleanup_conversation_external_resources(workspace_id)
    cleanup_workspace_files(workspace_id)
    :ok
  end

  defp cleanup_conversation_external_resources(workspace_id) do
    # Conversation :delete_full_conversation also cleans up the
    # conversation's files (S3 + storage_usage_bytes) and remote sandbox
    # sprites. Run it OUTSIDE the transaction so those network calls don't
    # extend the lock window.
    Magus.Chat.Conversation
    |> Ash.Query.filter(workspace_id == ^workspace_id and is_nil(deleted_at))
    |> Ash.bulk_destroy!(:delete_full_conversation, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true,
      stop_on_error?: false
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "WorkspaceDeletion.cleanup_conversation_external_resources: #{Exception.message(e)}"
      )

      :ok
  end

  defp cleanup_workspace_files(workspace_id) do
    # Files attached to conversations were already destroyed above. This
    # cleans up workspace-scoped files that were NOT attached to a
    # conversation (uploaded directly to the workspace).
    Magus.Files.File
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true,
      stop_on_error?: false
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "WorkspaceDeletion.cleanup_workspace_files: #{Exception.message(e)} — proceeding with delete; orphan storage objects may remain"
      )

      :ok
  end

  defp delete_in_transaction(workspace) do
    result =
      Magus.Repo.transaction(fn ->
        delete_workspace_owned_content(workspace.id)
        delete_workspace_row(workspace)
        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_workspace_owned_content(workspace_id) do
    # Phase 1: Cleanup cross-workspace references to resources we are
    # about to delete. Custom agents in this workspace may be referenced
    # from OTHER conversations (e.g., a personal conversation that used a
    # workspace agent). NULL those FKs so destroying the agents doesn't
    # FK-fail.
    nullify_agent_references_outside_workspace(workspace_id)

    # Phase 2: Cleanup tables that hold workspace-scoped FKs with NO
    # ACTION ON DELETE — these would block destroy_via_action calls below.
    cleanup_agent_aux_tables(workspace_id)

    # Phase 3: Destroy remaining content scoped to the workspace.
    # Conversations and files were already destroyed by
    # cleanup_external_resources/1 outside the transaction; the bulk
    # calls here are defensive no-ops for the rare case a new row was
    # created concurrently between the cleanup pass and this transaction.
    destroy_via_action(Magus.Chat.Conversation, :delete_full_conversation, workspace_id)
    destroy_scoped(Magus.Files.File, workspace_id)
    destroy_scoped(Magus.Library.Prompt, workspace_id)
    destroy_scoped(Magus.Skills.Skill, workspace_id)
    destroy_scoped(Magus.Knowledge.KnowledgeSource, workspace_id)

    # MCP servers cascade-delete via `mcp_servers.workspace_id ON DELETE :delete_all`
    # when the workspace row goes, which bypasses the Server :destroy hook that
    # cleans up resource_accesses grants. Destroy them through the Ash action
    # FIRST so DestroyResourceGrants fires (mirrors conversations/files/prompts).
    destroy_scoped(Magus.MCP.Server, workspace_id)

    # CustomAgent's :destroy is a soft delete. For workspace teardown we
    # want a true hard delete, so go straight to Ecto. Workspaces use
    # `on_delete: :nilify` for workspaces.default_agent_id, so this
    # nullifies the workspace's pointer automatically. Ecto bypass also
    # means the DestroyResourceGrants Ash hook does not fire, so grants
    # for these agents are cleaned up by cleanup_resource_accesses/1.
    delete_scoped_via_ecto(Magus.Agents.CustomAgent, workspace_id)

    cleanup_resource_accesses(workspace_id)
  end

  # Conversations and messages OUTSIDE this workspace may reference
  # custom_agents IN this workspace. NULL those FKs first; the columns
  # are nullable and `responding_agent_id`/`custom_agent_id` are
  # `ON DELETE NO ACTION`.
  defp nullify_agent_references_outside_workspace(workspace_id) do
    import Ecto.Query
    wid = uuid_binary(workspace_id)

    from(m in "messages",
      join: ca in "custom_agents",
      on: ca.id == m.responding_agent_id,
      where: ca.workspace_id == ^wid
    )
    |> Magus.Repo.update_all(set: [responding_agent_id: nil])

    from(c in "conversations",
      join: ca in "custom_agents",
      on: ca.id == c.custom_agent_id,
      where: ca.workspace_id == ^wid and c.workspace_id != ^wid
    )
    |> Magus.Repo.update_all(set: [custom_agent_id: nil])

    :ok
  end

  # Tables that hold custom_agent references with ON DELETE NO ACTION.
  # Must be cleaned BEFORE we delete the workspace's custom_agents rows.
  # Also handles `agent_runs.source_conversation_id` /
  # `target_conversation_id`, which point at workspace conversations and
  # would block the conversation destroy with the same NO ACTION FK.
  defp cleanup_agent_aux_tables(workspace_id) do
    wid = uuid_binary(workspace_id)

    for {table, column} <- [
          {"agent_activity_logs", "agent_id"},
          {"agent_inbox_events", "agent_id"},
          {"agent_runs", "target_agent_id"},
          {"user_integrations", "custom_agent_id"}
        ] do
      sql =
        "DELETE FROM #{table} WHERE #{column} IN " <>
          "(SELECT id FROM custom_agents WHERE workspace_id = $1)"

      try do
        Magus.Repo.query!(sql, [wid])
      rescue
        e ->
          Logger.warning(
            "WorkspaceDeletion.cleanup_agent_aux_tables (#{table}): #{Exception.message(e)}"
          )
      end
    end

    # agent_runs also has NO ACTION FKs back to conversations on
    # source_conversation_id and target_conversation_id. Clean any rows
    # referencing the workspace's conversations.
    Magus.Repo.query!(
      "DELETE FROM agent_runs WHERE source_conversation_id IN " <>
        "(SELECT id FROM conversations WHERE workspace_id = $1) OR " <>
        "target_conversation_id IN " <>
        "(SELECT id FROM conversations WHERE workspace_id = $1)",
      [wid]
    )

    # Memories pointing at workspace agents must be hard-deleted: the
    # `memories_agent_scope_requires_agent` CHECK constraint forbids
    # NULLing custom_agent_id while scope = :agent.
    import Ecto.Query

    from(m in "memories",
      join: ca in "custom_agents",
      on: ca.id == m.custom_agent_id,
      where: ca.workspace_id == ^wid
    )
    |> Magus.Repo.delete_all()

    :ok
  end

  # `resource_accesses` is polymorphic (no FK on resource_id) but rows
  # become orphaned when the underlying resource is destroyed. Ash
  # destroy hooks clean these up for conversations/files/prompts, but
  # custom_agents are deleted via Ecto (no hook), and grants where the
  # workspace itself is the grantee or resource need explicit cleanup.
  defp cleanup_resource_accesses(workspace_id) do
    wid = uuid_binary(workspace_id)

    Magus.Repo.query!(
      "DELETE FROM resource_accesses WHERE resource_type = 'custom_agent' AND resource_id IN " <>
        "(SELECT id FROM custom_agents WHERE workspace_id = $1)",
      [wid]
    )

    Magus.Repo.query!(
      "DELETE FROM resource_accesses WHERE grantee_type = 'workspace' AND grantee_id = $1",
      [wid]
    )

    :ok
  end

  defp delete_workspace_row(workspace) do
    wid = uuid_binary(workspace.id)

    # users.current_workspace_id has ON DELETE NO ACTION; clear it before
    # the workspace row goes.
    Magus.Repo.query!(
      "UPDATE users SET current_workspace_id = NULL WHERE current_workspace_id = $1",
      [wid]
    )

    # sessions.workspace_id has ON DELETE NO ACTION; sessions hold short-
    # lived auth state and can be safely removed.
    Magus.Repo.query!("DELETE FROM sessions WHERE workspace_id = $1", [wid])

    # workspace_members_versions.version_source_id has ON DELETE NO ACTION
    # back to workspace_members, so version rows must go before the
    # member rows. Audit history is lost with the workspace — this is a
    # hard delete.
    Magus.Repo.query!(
      "DELETE FROM workspace_members_versions WHERE version_source_id IN " <>
        "(SELECT id FROM workspace_members WHERE workspace_id = $1)",
      [wid]
    )

    # workspace_members.workspace_id has ON DELETE NO ACTION; hard-delete
    # the membership rows.
    Magus.Repo.query!("DELETE FROM workspace_members WHERE workspace_id = $1", [wid])

    # Paper-trail history for the workspace itself.
    Magus.Repo.query!(
      "DELETE FROM workspaces_versions WHERE version_source_id = $1",
      [wid]
    )

    # Drop the workspace row. CASCADE FKs handle folders, brains,
    # knowledge_collections, memories, and tab_sessions automatically.
    Magus.Repo.delete!(workspace)
  end

  # Like AccountDeletion.destroy_owned/2 but scoped by workspace_id.
  defp destroy_scoped(resource, workspace_id) do
    resource
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true
    )
  rescue
    e ->
      Logger.warning(
        "WorkspaceDeletion: bulk_destroy on #{inspect(resource)} failed: #{Exception.message(e)}"
      )

      reraise e, __STACKTRACE__
  end

  defp destroy_via_action(resource, action, workspace_id) do
    resource
    |> Ash.Query.filter(workspace_id == ^workspace_id)
    |> Ash.bulk_destroy!(action, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true
    )
  rescue
    e ->
      Logger.warning(
        "WorkspaceDeletion: bulk_destroy(#{inspect(action)}) on #{inspect(resource)} failed: #{Exception.message(e)}"
      )

      reraise e, __STACKTRACE__
  end

  # Resources without a hard-destroy action (CustomAgent's :destroy is a
  # soft delete). Ash resources double as Ecto schemas, so we can pass
  # the module to Repo.delete_all directly.
  defp delete_scoped_via_ecto(resource, workspace_id) do
    require Ecto.Query

    resource
    |> Ecto.Query.from(where: [workspace_id: ^workspace_id])
    |> Magus.Repo.delete_all()

    :ok
  end

  defp uuid_binary(id), do: Ecto.UUID.dump!(to_string(id))
end
