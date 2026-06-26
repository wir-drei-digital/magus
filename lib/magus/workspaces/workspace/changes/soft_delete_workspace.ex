defmodule Magus.Workspaces.Workspace.Changes.SoftDeleteWorkspace do
  @moduledoc """
  Performs soft-delete cleanup for a workspace:

  - Deactivates all members (status: :deactivated, is_active: false)
  - Nilifies `workspace_id` on owned resources so they revert to personal scope
    (conversations, files, prompts, custom agents, knowledge sources)
  - Clears `current_workspace_id` on users who had this workspace selected

  The workspace itself is left in place with `is_active: false` so it can be
  inspected in admin, audited, or potentially restored.
  """
  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, workspace ->
      deactivate_members(workspace.id)
      nilify_child_workspace_ids(workspace.id)
      clear_current_workspace_on_users(workspace.id)
      broadcast_deactivated(workspace)
      {:ok, workspace}
    end)
  end

  defp broadcast_deactivated(workspace) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "workspaces:#{workspace.id}",
      {:workspace_deactivated, workspace.id}
    )
  end

  defp deactivate_members(workspace_id) do
    # authorize?: false is safe here — this change runs from the Workspace
    # :deactivate action, which is itself gated to workspace admins.
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(workspace_id == ^workspace_id and status != :deactivated)
    |> Ash.bulk_update!(:deactivate, %{for_workspace_removal: true},
      authorize?: false,
      strategy: :stream,
      return_errors?: true
    )
  end

  defp nilify_child_workspace_ids(workspace_id) do
    resources = [
      {Magus.Chat.Conversation, "conversations"},
      {Magus.Files.File, "files"},
      {Magus.Library.Prompt, "prompts"},
      {Magus.Agents.CustomAgent, "custom_agents"},
      {Magus.Knowledge.KnowledgeSource, "knowledge_sources"}
    ]

    Enum.each(resources, fn {module, table} ->
      nilify_via_ecto(module, table, workspace_id)
    end)
  end

  defp nilify_via_ecto(_module, table, workspace_id) do
    import Ecto.Query

    from(r in table, where: r.workspace_id == ^workspace_id)
    |> Magus.Repo.update_all(set: [workspace_id: nil])
  rescue
    error ->
      Logger.warning(
        "SoftDeleteWorkspace: failed to nilify workspace_id on #{table}: #{Exception.message(error)}"
      )
  end

  defp clear_current_workspace_on_users(workspace_id) do
    import Ecto.Query

    from(u in "users", where: u.current_workspace_id == ^workspace_id)
    |> Magus.Repo.update_all(set: [current_workspace_id: nil])
  rescue
    error ->
      Logger.warning(
        "SoftDeleteWorkspace: failed to clear current_workspace_id on users: #{Exception.message(error)}"
      )
  end
end
