defmodule Magus.Memory.UserProfileVersion do
  @moduledoc """
  Immutable snapshot of a UserProfile document, captured on every
  set_document. Mirrors MemoryVersion.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Memory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_profile_versions"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:document, :token_estimate, :changed_by]
      argument :user_profile_id, :uuid, allow_nil?: false
      change manage_relationship(:user_profile_id, :user_profile, type: :append)
    end

    read :for_profile do
      argument :user_profile_id, :uuid, allow_nil?: false
      filter expr(user_profile_id == ^arg(:user_profile_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    bypass action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
      authorize_if relates_to_actor_via([:user_profile, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :document, :string,
      allow_nil?: false,
      default: "",
      constraints: [allow_empty?: true, trim?: false]

    attribute :token_estimate, :integer, allow_nil?: false, default: 0

    attribute :changed_by, :atom do
      constraints one_of: [:distiller, :system]
      default :system
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user_profile, Magus.Memory.UserProfile, allow_nil?: false
  end
end
