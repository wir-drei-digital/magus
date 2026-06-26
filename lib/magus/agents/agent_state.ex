defmodule Magus.Agents.AgentState do
  @moduledoc """
  Ash resource for persisting agent state in PostgreSQL.

  Used by the Jido.Storage implementation to save and restore agent state
  across hibernation/thaw cycles. Stores serialized agent data for recovery.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agent_states"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :by_key do
      description "Read agent state by agent_module and agent_id"
      argument :agent_module, :string, allow_nil?: false
      argument :agent_id, :string, allow_nil?: false

      filter expr(agent_module == ^arg(:agent_module) and agent_id == ^arg(:agent_id))
    end

    create :upsert do
      description "Create or update agent state"
      upsert? true
      upsert_identity :agent_key

      accept [:agent_module, :agent_id, :state_data, :version]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_module, :string do
      allow_nil? false
      description "Module name of the agent (e.g., 'Magus.Agents.ConversationAgent')"
    end

    attribute :agent_id, :string do
      allow_nil? false
      description "Unique agent instance ID (e.g., 'conv:conversation-uuid')"
    end

    attribute :state_data, :map do
      allow_nil? false
      description "Serialized agent state data"
    end

    attribute :version, :integer do
      allow_nil? false
      default 1
      description "State version for migration tracking"
    end

    timestamps type: :utc_datetime_usec
  end

  identities do
    identity :agent_key, [:agent_module, :agent_id] do
      description "Unique constraint on agent module and ID"
    end

    identity :id, [:id]
  end
end
