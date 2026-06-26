defmodule Magus.Agents.CustomAgentAttachment do
  @moduledoc """
  Join resource between `CustomAgent` and `Magus.Files.File`.

  Each row attaches a file to a custom agent in either always-include
  (full text in the system prompt) or search (RAG, tool-driven) mode.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "custom_agent_attachments"
    repo Magus.Repo

    references do
      reference :custom_agent, on_delete: :delete
      reference :file, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:custom_agent_id, :file_id, :mode, :position]
      validate Magus.Agents.CustomAgentAttachment.Validations.WithinLimits
      change Magus.Agents.CustomAgentAttachment.Changes.GrantAgentAccess
    end

    update :update do
      primary? true
      accept [:mode, :position]
      require_atomic? false
      validate Magus.Agents.CustomAgentAttachment.Validations.WithinLimits
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Magus.Agents.CustomAgentAttachment.Changes.RevokeAgentAccess
    end

    read :for_agent do
      argument :custom_agent_id, :uuid, allow_nil?: false
      filter expr(custom_agent_id == ^arg(:custom_agent_id))
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :mode, :atom do
      constraints one_of: [:always, :search]
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      default 0
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :custom_agent, Magus.Agents.CustomAgent do
      allow_nil? false
      public? true
    end

    belongs_to :file, Magus.Files.File do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_agent_file, [:custom_agent_id, :file_id]
  end
end
