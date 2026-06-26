defmodule Magus.Memory.MemoryVersion do
  @moduledoc """
  Stores historical versions of memory content.

  Each time a memory is modified, a new version is created containing
  a snapshot of the content. This enables debugging and potential
  rollback functionality.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "memory_versions"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:content, :summary, :version, :changed_by, :change_description]
      argument :memory_id, :uuid, allow_nil?: false
      change set_attribute(:memory_id, arg(:memory_id))
    end

    read :for_memory do
      argument :memory_id, :uuid, allow_nil?: false
      filter expr(memory_id == ^arg(:memory_id))
      prepare build(sort: [version: :desc])
    end
  end

  policies do
    # Versions are readable by anyone who can read the parent memory
    policy action_type(:read) do
      authorize_if expr(memory.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       memory.conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )
    end

    # Only system can create versions (via CreateVersion change)
    policy action_type(:create) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :content, :map, allow_nil?: false, public?: true
    attribute :summary, :string, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true

    attribute :changed_by, :atom,
      constraints: [one_of: [:agent, :user, :system, :extraction]],
      public?: true

    attribute :change_description, :string, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :memory, Magus.Memory.Memory, allow_nil?: false
  end
end
