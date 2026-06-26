defmodule Magus.Agents.CustomAgent.Preparations.MyAgentsAccess do
  @moduledoc """
  Preparation for the `:my_agents` read action.

  Returns custom agents the actor either owns (`user_id == actor.id`) or has
  access to via a `Magus.Workspaces.ResourceAccess` grant. Two grant paths
  are considered:

    * direct-user grant (`grantee_type == :user`) matching the actor's id
    * workspace-level grant (`grantee_type == :workspace`) where the actor is
      an active member of that workspace

  The lookup runs imperatively (via `Ash.read!/2` with `authorize?: false`) to
  avoid the limitations of cross-resource `exists/2` inside an Ash filter
  expression. The collected agent IDs are folded back into the main filter
  alongside `user_id == ^actor(:id)`.
  """

  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    accessible_ids = accessible_agent_ids_for(actor_id)

    Ash.Query.filter(query, user_id == ^actor_id or id in ^accessible_ids)
  end

  # No authenticated user: let the policy layer deny the query. We still
  # collapse to an always-false filter to avoid reading the full table.
  def prepare(query, _opts, _context) do
    Ash.Query.filter(query, false)
  end

  defp accessible_agent_ids_for(actor_id) do
    workspace_ids = active_workspace_ids(actor_id)

    Magus.Workspaces.ResourceAccess
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      resource_type == :custom_agent and
        ((grantee_type == :user and grantee_id == ^actor_id) or
           (grantee_type == :workspace and grantee_id in ^workspace_ids))
    )
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.resource_id)
    |> Enum.uniq()
  end

  defp active_workspace_ids(actor_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^actor_id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.workspace_id)
  end
end
