defmodule Magus.Memory.Memory.Changes.DeriveWorkspaceFromCustomAgent do
  @moduledoc """
  On `:agent` memory create, copies workspace_id from the parent custom agent.

  Rejects the change if the caller passed a workspace_id that doesn't match
  the agent's workspace_id.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      agent_id = Ash.Changeset.get_argument(cs, :custom_agent_id)

      case load_agent(agent_id) do
        nil ->
          cs

        agent ->
          existing = Ash.Changeset.get_attribute(cs, :workspace_id)

          if not is_nil(existing) and existing != agent.workspace_id do
            Ash.Changeset.add_error(cs,
              field: :workspace_id,
              message: "must match the custom agent's workspace_id"
            )
          else
            Ash.Changeset.force_change_attribute(cs, :workspace_id, agent.workspace_id)
          end
      end
    end)
  end

  defp load_agent(nil), do: nil

  defp load_agent(id) do
    case Magus.Agents.CustomAgent
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.select([:id, :workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, agent} -> agent
      _ -> nil
    end
  end
end
