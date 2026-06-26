defmodule Magus.Memory.MemorySource do
  @moduledoc """
  Tracks the provenance of a memory — where it was created or derived from.

  Each memory can have multiple sources, such as conversations, files, URLs,
  or manual entries, providing an audit trail of how knowledge was acquired.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memory_sources"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:source_type, :source_uri, :title, :context_snippet]
      argument :memory_id, :uuid, allow_nil?: false
      change manage_relationship(:memory_id, :memory, type: :append)
    end
  end

  policies do
    bypass action_type([:read, :create, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:memory, :user])
    end

    policy action_type([:create, :destroy]) do
      authorize_if relates_to_actor_via([:memory, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :source_type, :atom do
      allow_nil? false
      constraints one_of: [:conversation, :file, :url, :manual]
      public? true
    end

    attribute :source_uri, :string, public?: true
    attribute :title, :string, public?: true
    attribute :context_snippet, :string, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :memory, Magus.Memory.Memory, allow_nil?: false
  end

  identities do
    identity :memory_source_lookup, [:memory_id, :source_type, :source_uri]
  end
end
