defmodule Magus.Skills.SkillTrust do
  @moduledoc """
  Per-user "always allow this skill" grant. A trusted skill skips the approval
  card in every conversation. Records the bundle sha at grant time; a later
  content change stales the trust (re-prompts once).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "skill_trusts"
    repo Magus.Repo

    references do
      reference :skill, on_delete: :delete
    end
  end

  typescript do
    type_name "SkillTrust"
  end

  actions do
    defaults [:read, :destroy]

    read :my_trusts do
      filter expr(user_id == ^actor(:id))
    end

    create :create do
      argument :skill_id, :uuid, allow_nil?: false
      change set_attribute(:skill_id, arg(:skill_id))
      change relate_actor(:user)
      change Magus.Skills.SkillTrust.Changes.SnapshotSha
    end
  end

  policies do
    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :bundle_sha_at_grant, :string, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :skill, Magus.Skills.Skill, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_user_skill, [:user_id, :skill_id]
  end
end
