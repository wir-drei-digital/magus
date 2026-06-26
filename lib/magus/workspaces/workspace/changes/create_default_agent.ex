defmodule Magus.Workspaces.Workspace.Changes.CreateDefaultAgent do
  @moduledoc """
  After a workspace is created, provision a workspace-scoped "Workspace Assistant"
  CustomAgent, share it with all workspace members, and point the workspace's
  `default_agent_id` at it.

  This enforces strict workspace separation: conversations created inside a
  workspace use the workspace's shared default agent rather than spilling over
  to the creator's personal default.

  Provisioning is delegated to `Magus.Agents.ensure_workspace_default_agent/2`
  so the same code path also serves as lazy backfill for legacy workspaces and
  recovery if the default agent is later deleted.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, workspace ->
      case Magus.Agents.ensure_workspace_default_agent(workspace, context.actor) do
        {:ok, _agent} ->
          {:ok, Ash.reload!(workspace, actor: context.actor)}

        {:error, reason} ->
          Logger.warning(
            "workspace #{workspace.id}: default agent provisioning failed: " <>
              inspect(reason)
          )

          {:ok, workspace}
      end
    end)
  end
end
