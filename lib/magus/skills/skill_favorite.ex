defmodule Magus.Skills.SkillFavorite do
  @moduledoc """
  Tracks user favorites for skills.
  """
  use Ash.Resource,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "skill_favorites"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :skill, on_delete: :delete
    end
  end

  typescript do
    type_name "SkillFavorite"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :my_favorites do
      filter expr(user_id == ^actor(:id))
    end

    create :create do
      accept [:skill_id]
      change relate_actor(:user)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if Magus.Skills.SkillFavorite.Checks.ActorCanReadSkill
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :skill, Magus.Skills.Skill do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_skill_favorite, [:user_id, :skill_id]
  end
end
