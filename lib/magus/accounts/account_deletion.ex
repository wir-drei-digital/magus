defmodule Magus.Accounts.AccountDeletion do
  @moduledoc """
  Hard-delete a user account and everything they own, with safety
  guards: refuses if the user is the sole admin of any workspace, and
  runs the `Magus.Usage.AccountLifecycle` deletion hook BEFORE the
  deletion transaction begins. The hook is a no-op in the open-core
  default; the billing edition cancels the active subscription there. A
  hook failure (`{:error, :lifecycle_aborted}`) aborts the flow with no
  DB writes, so the user can retry; the inverse failure mode (account
  deleted, billing still active) would be much worse.
  """
  require Ash.Query
  require Logger

  alias Magus.Accounts.User
  alias Magus.Workspaces.Workspace
  alias Magus.Workspaces.WorkspaceMember

  @type summary :: %{
          active_subscription: %{plan: String.t(), current_period_end: DateTime.t() | nil} | nil,
          multiplayer_membership_count: non_neg_integer(),
          conversation_count: non_neg_integer(),
          brain_count: non_neg_integer(),
          memory_count: non_neg_integer(),
          prompt_count: non_neg_integer(),
          draft_count: non_neg_integer(),
          custom_agent_count: non_neg_integer()
        }

  @spec preflight(User.t()) ::
          {:ok, summary()} | {:error, :sole_admin_workspaces, [Workspace.t()]}
  def preflight(%User{} = user) do
    case sole_admin_workspaces(user.id) do
      [] -> {:ok, build_summary(user)}
      workspaces -> {:error, :sole_admin_workspaces, workspaces}
    end
  end

  defp sole_admin_workspaces(user_id) do
    admin_ws_ids =
      WorkspaceMember
      |> Ash.Query.filter(user_id == ^user_id and is_active == true and role == :admin)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.workspace_id)

    Enum.filter(admin_ws_ids, fn ws_id ->
      other_admin_count =
        WorkspaceMember
        |> Ash.Query.filter(
          workspace_id == ^ws_id and is_active == true and role == :admin and
            user_id != ^user_id
        )
        |> Ash.count!(authorize?: false)

      other_admin_count == 0
    end)
    |> Enum.map(fn ws_id ->
      Workspace
      |> Ash.Query.filter(id == ^ws_id)
      |> Ash.read_one!(authorize?: false)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_summary(user) do
    %{
      active_subscription: load_active_subscription(user.id),
      multiplayer_membership_count: count_multiplayer_memberships(user.id),
      conversation_count: count_owned(Magus.Chat.Conversation, user.id),
      brain_count: count_owned(Magus.Brain.BrainResource, user.id),
      memory_count: count_owned(Magus.Memory.Memory, user.id),
      prompt_count: count_owned(Magus.Library.Prompt, user.id),
      draft_count: count_owned(Magus.Drafts.Draft, user.id),
      custom_agent_count: count_owned(Magus.Agents.CustomAgent, user.id)
    }
  end

  defp count_owned(resource, user_id) do
    resource
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.count!(authorize?: false)
  rescue
    e in UndefinedFunctionError ->
      Logger.warning(
        "AccountDeletion: count_owned skipped for #{inspect(resource)}: #{Exception.message(e)}"
      )

      0
  end

  defp count_multiplayer_memberships(user_id) do
    Magus.Chat.ConversationMember
    |> Ash.Query.filter(user_id == ^user_id and not is_nil(accepted_at))
    |> Ash.count!(authorize?: false)
  rescue
    e in UndefinedFunctionError ->
      Logger.warning(
        "AccountDeletion: count_multiplayer_memberships skipped: #{Exception.message(e)}"
      )

      0
  end

  defp load_active_subscription(user_id) do
    Magus.Usage.Account
    |> Ash.Query.filter(user_id == ^user_id and is_nil(sponsor_user_id) and status == :active)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = sub} ->
        plan =
          case Ash.load(sub, :usage_plan, authorize?: false) do
            {:ok, loaded} -> loaded.usage_plan && loaded.usage_plan.key
            _ -> nil
          end

        %{plan: plan, current_period_end: sub.current_period_end}

      _ ->
        nil
    end
  end

  @doc """
  Hard-delete the given user's owned content and the User row itself.

  Re-runs `preflight/1` first to defend against modal-time staleness;
  if the user has become a sole admin in the meantime, returns the
  same `{:error, :sole_admin_workspaces, _}` tuple and writes nothing.

  The `Magus.Usage.AccountLifecycle` deletion hook runs BEFORE the
  deletion transaction starts (a no-op in open core; the billing edition
  cancels the subscription there). A hook failure must abort the whole
  flow with no DB writes: the inverse failure mode (account gone, billing
  still active) is much worse than the user being able to retry.

  Beyond the lifecycle hook + the User row + owned content, this also
  anonymizes message_usage rows so aggregate billing / statistics survive
  the user's deletion.
  """
  @spec execute(User.t()) ::
          :ok
          | {:error, :sole_admin_workspaces, [Workspace.t()]}
          | {:error, :lifecycle_aborted | term()}
  def execute(%User{} = user) do
    with {:ok, _summary} <- preflight(user),
         :ok <- Magus.Usage.AccountLifecycle.on_deletion(user.id) do
      cleanup_external_resources(user)
      delete_in_transaction(user)
    end
  end

  # Best-effort cleanup of S3 / sandbox / other external systems for resources
  # the user owns. Runs OUTSIDE the DB transaction so external network calls
  # (sandbox provider, S3, FalkorDB) don't hold Postgres locks across multi-second
  # round trips or risk hitting idle_in_transaction_timeout. Failures here are
  # logged but do not block the delete: the data they reference is about to be
  # removed from our DB anyway, and orphaned external blobs are far less bad
  # than failing the whole delete because an external service had a hiccup.
  defp cleanup_external_resources(user) do
    delete_user_files_with_storage_cleanup(user.id)
    cleanup_user_conversation_external_resources(user.id)
    # SuperBrain owns four personal FalkorDB graphs plus its own Postgres
    # bookkeeping (SuperGraph / Episode / ExtractionBudget) that has no FK to
    # `users`. `purge_user/1` is best-effort and logs internally; it never
    # raises so the rest of the deletion still proceeds.
    Magus.SuperBrain.Cleanup.purge_user(user.id)
    :ok
  end

  defp delete_user_files_with_storage_cleanup(user_id) do
    Magus.Files.File
    |> Ash.Query.filter(user_id == ^user_id)
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
        "AccountDeletion.delete_user_files_with_storage_cleanup: #{Exception.message(e)} — proceeding with delete; orphan storage objects may remain"
      )

      :ok
  end

  defp cleanup_user_conversation_external_resources(user_id) do
    # The Conversation :delete_full_conversation action does S3 + sandbox
    # cleanup as part of its destroy hook. Run it OUTSIDE the transaction so
    # those network calls don't extend the transaction's lock window. The
    # transaction-side step then re-runs :delete_full_conversation as a
    # no-op for the rows already gone (or finds none to delete).
    Magus.Chat.Conversation
    |> Ash.Query.filter(user_id == ^user_id and is_nil(deleted_at))
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
        "AccountDeletion.cleanup_user_conversation_external_resources: #{Exception.message(e)}"
      )

      :ok
  end

  defp delete_in_transaction(user) do
    result =
      Magus.Repo.transaction(fn ->
        delete_user_owned_content(user)
        delete_user_row(user)
        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_user_owned_content(user) do
    # Phase 1: Anonymize references in OTHER users' content (must happen before
    # we destroy our own content because some of these reference the same tables).
    nullify_messages_authored_by_user(user.id)
    nullify_message_usage(user.id)

    # Phase 2: Cleanup tables that block conversation/custom_agent destroys
    # (NO ACTION FKs that pgsql will refuse to cascade).
    cleanup_conversation_aux_tables(user.id)
    cleanup_custom_agent_aux_tables(user.id)

    # Phase 3: Destroy user-owned content (FK-safe order). Files and conversations
    # were already destroyed by cleanup_external_resources/1 outside the transaction
    # so their S3 / sandbox network calls didn't hold pg locks.
    destroy_owned(Magus.Drafts.Draft, user.id)
    destroy_owned(Magus.Library.PromptFavorite, user.id)
    destroy_owned(Magus.Library.Prompt, user.id)
    destroy_owned(Magus.Memory.Memory, user.id)
    destroy_owned(Magus.Brain.BrainResource, user.id)

    # Conversations were destroyed by cleanup_external_resources/1 above; this
    # is a defensive no-op for the rare case a new one was created concurrently
    # between the cleanup pass and this transaction. Conversation has no
    # :destroy action; :delete_full_conversation is the canonical hard-delete
    # path (cleans up files + sandbox sprites).
    destroy_via_action(Magus.Chat.Conversation, :delete_full_conversation, user.id)

    # Owned models/providers (BYOK). Runs after conversations so the user's
    # messages and their message_usage rows are already gone; any usage rows
    # still pointing at an owned model get their model_id nilled below.
    delete_owned_models_and_providers(user.id)

    # CustomAgent's :destroy is a soft delete that also rejects the
    # default agent. For account-deletion we want a true hard delete,
    # so go straight to Ecto. Must come AFTER conversations are gone
    # (conversations.custom_agent_id is NO ACTION but we NULL it in
    # cleanup_custom_agent_aux_tables for OTHER users' conversations).
    delete_owned_via_ecto(Magus.Agents.CustomAgent, user.id)

    # Folders must come AFTER conversations (conversations.folder_id is
    # NO ACTION; user's conversations cleared above).
    delete_owned_via_ecto(Magus.Chat.Folder, user.id)

    # WorkspaceMember has no :destroy action defined (only :deactivate).
    # Hard-delete the rows directly so the user's membership is gone.
    delete_owned_via_ecto(Magus.Workspaces.WorkspaceMember, user.id)

    destroy_owned(Magus.Chat.ConversationMember, user.id)
  end

  # NULL out message authorship in OTHER users' conversations (the user's
  # own conversations cascade-delete naturally). Also NULL responding_agent_id
  # everywhere it points at one of this user's agents, since those agents are
  # about to be destroyed and that FK is NO ACTION.
  defp nullify_messages_authored_by_user(user_id) do
    import Ecto.Query
    uid = user_id_uuid_binary(user_id)

    from(m in "messages",
      join: c in "conversations",
      on: c.id == m.conversation_id,
      where: m.created_by_id == ^uid and c.user_id != ^uid
    )
    |> Magus.Repo.update_all(set: [created_by_id: nil])

    from(m in "messages",
      join: ca in "custom_agents",
      on: ca.id == m.responding_agent_id,
      where: ca.user_id == ^uid
    )
    |> Magus.Repo.update_all(set: [responding_agent_id: nil])

    :ok
  end

  # Anonymize this user's message_usage records by NULLing the FK so the rows
  # survive for aggregate billing/statistics. The column was made nullable in
  # migration 20260426001319_allow_null_message_usage_user_id.
  defp nullify_message_usage(user_id) do
    import Ecto.Query
    uid = user_id_uuid_binary(user_id)

    from(u in "message_usages", where: u.user_id == ^uid)
    |> Magus.Repo.update_all(set: [user_id: nil])

    :ok
  end

  # Tables that hold conversation_id with ON DELETE NO ACTION and would
  # block conversation destroys. Limit to rows that reference the user's
  # OWN conversations (we only destroy those).
  defp cleanup_conversation_aux_tables(user_id) do
    import Ecto.Query
    uid = user_id_uuid_binary(user_id)

    from(ps in "pane_states",
      join: c in "conversations",
      on: c.id == ps.conversation_id,
      where: c.user_id == ^uid
    )
    |> Magus.Repo.delete_all()

    # plan_task_pane_states.conversation_id is CASCADE per migration
    # 20260321100000, but defensively clean it here too in case the FK
    # ever changes. Wrapped in try/rescue so an unexpected schema change
    # doesn't break account deletion.
    try do
      from(ps in "plan_task_pane_states",
        join: c in "conversations",
        on: c.id == ps.conversation_id,
        where: c.user_id == ^uid
      )
      |> Magus.Repo.delete_all()
    rescue
      e ->
        Logger.warning(
          "AccountDeletion.cleanup_conversation_aux_tables (plan_task_pane_states): #{Exception.message(e)}"
        )
    end

    :ok
  end

  # Tables that hold custom_agent references with ON DELETE NO ACTION. Must
  # be cleaned (or NULLed) BEFORE we destroy the user's custom_agents rows.
  defp cleanup_custom_agent_aux_tables(user_id) do
    import Ecto.Query
    uid = user_id_uuid_binary(user_id)

    # Hard-delete dependents that hold a NOT NULL agent reference.
    for {table, column} <- [
          {"agent_activity_logs", "agent_id"},
          {"agent_inbox_events", "agent_id"},
          {"agent_runs", "target_agent_id"},
          {"user_integrations", "custom_agent_id"}
        ] do
      sql =
        "DELETE FROM #{table} WHERE #{column} IN " <>
          "(SELECT id FROM custom_agents WHERE user_id = $1)"

      try do
        Magus.Repo.query!(sql, [uid])
      rescue
        e ->
          Logger.warning(
            "AccountDeletion.cleanup_custom_agent_aux_tables (#{table}): #{Exception.message(e)}"
          )
      end
    end

    # Memories pointing at this user's agents must be hard-deleted: the
    # `memories_agent_scope_requires_agent` CHECK constraint forbids
    # NULLing custom_agent_id while scope = :agent. Those memories are
    # meaningless without the owning agent.
    from(m in "memories",
      join: ca in "custom_agents",
      on: ca.id == m.custom_agent_id,
      where: ca.user_id == ^uid
    )
    |> Magus.Repo.delete_all()

    # Conversations pointing at this user's agents (own + others') get
    # their custom_agent_id NULLed. Other users' conversations must
    # survive the agent destroy.
    from(c in "conversations",
      join: ca in "custom_agents",
      on: ca.id == c.custom_agent_id,
      where: ca.user_id == ^uid
    )
    |> Magus.Repo.update_all(set: [custom_agent_id: nil])

    :ok
  end

  # Auxiliary tables that hold user_id with ON DELETE NO ACTION and
  # would block the final User row delete. These hold incidental data
  # (audit logs, feature counters, sessions, integrations, notifications,
  # etc.) and must be removed before the User row can be dropped.
  #
  # Tables already covered by an Ash domain destroy above (drafts,
  # prompts, custom_agents, conversations, workspace_members, files,
  # etc.) are NOT listed here. Files in particular are destroyed via
  # the Ash :destroy action in cleanup_external_resources/1 so the
  # S3 + storage_usage_bytes accounting hooks fire properly.
  #
  # Format: {table, column}.
  @auxiliary_user_tables [
    {"agent_activity_logs", "user_id"},
    {"agent_inbox_events", "user_id"},
    {"conversation_share_links", "created_by_id"},
    {"curation_inbox_items", "user_id"},
    {"curation_interest_profiles", "user_id"},
    {"curation_sources", "user_id"},
    {"feature_usage_events", "user_id"},
    {"ingestion_entries", "user_id"},
    {"integration_audit_logs", "user_id"},
    {"integration_input_messages", "user_id"},
    {"integration_output_messages", "user_id"},
    {"knowledge_sources", "user_id"},
    {"notifications", "user_id"},
    {"pane_states", "user_id"},
    {"plan_task_pane_states", "user_id"},
    {"sessions", "created_by_id"},
    {"user_integrations", "user_id"},
    {"user_subscriptions", "user_id"},
    {"user_usage_overrides", "user_id"}
  ]

  defp delete_auxiliary_user_rows(user_id) do
    uid = user_id_uuid_binary(user_id)

    # user_subscriptions_versions.version_source_id has ON DELETE NO ACTION
    # back to user_subscriptions, so version rows tied to this user's
    # subscriptions must be cleared before we can delete the rows themselves.
    # Audit history is lost for these specific subscriptions, but they are
    # gone too — this is a hard delete, not a soft one.
    Magus.Repo.query!(
      "DELETE FROM user_subscriptions_versions WHERE version_source_id IN " <>
        "(SELECT id FROM user_subscriptions WHERE user_id = $1)",
      [uid]
    )

    for {table, column} <- @auxiliary_user_tables do
      Magus.Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [uid])
    end

    # resource_accesses.granted_by_id has ON DELETE NO ACTION too;
    # nullify so we don't lose grants the user issued to others.
    Magus.Repo.query!(
      "UPDATE resource_accesses SET granted_by_id = NULL WHERE granted_by_id = $1",
      [uid]
    )

    :ok
  end

  defp destroy_owned(resource, user_id) do
    resource
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true
    )
  rescue
    e ->
      Logger.warning(
        "AccountDeletion: bulk_destroy on #{inspect(resource)} failed: #{Exception.message(e)}"
      )

      reraise e, __STACKTRACE__
  end

  defp destroy_via_action(resource, action, user_id) do
    resource
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.bulk_destroy!(action, %{},
      authorize?: false,
      strategy: :stream,
      allow_stream_with: :full_read,
      return_errors?: true
    )
  rescue
    e ->
      Logger.warning(
        "AccountDeletion: bulk_destroy(#{inspect(action)}) on #{inspect(resource)} failed: #{Exception.message(e)}"
      )

      reraise e, __STACKTRACE__
  end

  # Bypass Ash for resources that lack a true hard-destroy action.
  # Schemas are wired through Ash.Resource so we can use the module name
  # as the Ecto schema directly with Repo.delete_all.
  defp delete_owned_via_ecto(resource, user_id) do
    require Ecto.Query

    resource
    |> Ecto.Query.from(where: [user_id: ^user_id])
    |> Magus.Repo.delete_all()

    :ok
  end

  defp delete_user_row(user) do
    # Auxiliary tables that hold user_id with ON DELETE NO ACTION
    # (audit logs, sessions, notifications, integrations, etc.) must
    # be cleared before the User row can be dropped.
    delete_auxiliary_user_rows(user.id)

    # Paper-trail _versions tables hold the actor user_id with
    # ON DELETE NOTHING, so we must nullify those references before
    # the User row can be removed. Audit history is preserved; only
    # actor attribution is lost.
    nullify_paper_trail_actor(user.id)

    # User has no :destroy action defined on the Ash resource. Delete
    # the row directly via Ecto inside the surrounding transaction.
    Magus.Repo.delete!(user)
  end

  @paper_trail_tables ~w(
    prompts_versions
    drafts_versions
    brain_blocks_versions
    user_subscriptions_versions
    workspaces_versions
    workspace_members_versions
  )

  defp nullify_paper_trail_actor(user_id) do
    uid = user_id_uuid_binary(user_id)

    for table <- @paper_trail_tables do
      Magus.Repo.query!(
        "UPDATE #{table} SET user_id = NULL WHERE user_id = $1",
        [uid]
      )
    end

    :ok
  end

  # Deletes the user's owned models and providers (BYOK). Ordering matters:
  # models reference providers (NO ACTION FK), so models must go first.
  # message_usages.model_id auto-nilifies on model delete (ON DELETE SET NULL,
  # migration 20251226212252), so it never restricts the delete; we still
  # nil it out explicitly below as a redundant defensive safeguard.
  defp delete_owned_models_and_providers(user_id) do
    import Ecto.Query
    uid = user_id_uuid_binary(user_id)

    owned_model_ids =
      from(m in "models", where: m.owner_user_id == ^uid, select: m.id)
      |> Magus.Repo.all()

    # message_usages.model_id is ON DELETE SET NULL, so Postgres would nilify
    # these rows on the model delete anyway. Doing it here first is a redundant
    # defensive safeguard, not a restriction workaround. These usage rows belong
    # to the owner's own (already-deleted) messages in 2b-1, since owned models
    # are private.
    if owned_model_ids != [] do
      from(mu in "message_usages", where: mu.model_id in ^owned_model_ids)
      |> Magus.Repo.update_all(set: [model_id: nil])
    end

    # Models reference providers (NO ACTION), so delete models before providers.
    from(m in "models", where: m.owner_user_id == ^uid) |> Magus.Repo.delete_all()
    from(p in "model_providers", where: p.owner_user_id == ^uid) |> Magus.Repo.delete_all()
  end

  defp user_id_uuid_binary(user_id) do
    Ecto.UUID.dump!(to_string(user_id))
  end
end
