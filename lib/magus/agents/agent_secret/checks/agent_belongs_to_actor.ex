defmodule Magus.Agents.AgentSecret.Checks.AgentBelongsToActor do
  @moduledoc """
  Policy check that verifies the custom_agent_id in a create changeset refers
  to an agent owned by the current actor.

  Used for create actions where `relates_to_actor_via` cannot be used because
  the record does not yet exist in the database.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "custom_agent_id refers to an agent belonging to the current actor"
  end

  @impl true
  def match?(actor, %{changeset: changeset}, _opts) when not is_nil(actor) do
    custom_agent_id = Ash.Changeset.get_attribute(changeset, :custom_agent_id)

    case custom_agent_id do
      nil ->
        false

      agent_id ->
        case Magus.Agents.get_custom_agent(agent_id, actor: actor) do
          {:ok, _agent} -> true
          _ -> false
        end
    end
  end

  def match?(_actor, _context, _opts), do: false
end
