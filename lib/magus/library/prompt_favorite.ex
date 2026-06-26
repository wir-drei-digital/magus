defmodule Magus.Library.PromptFavorite do
  @moduledoc """
  Tracks user favorites for prompts.
  """
  use Ash.Resource,
    domain: Magus.Library,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "prompt_favorites"
    repo Magus.Repo
  end

  typescript do
    type_name "PromptFavorite"
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
      accept [:prompt_id]
      change relate_actor(:user)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if Magus.Library.PromptFavorite.Checks.ActorCanReadPrompt
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

    belongs_to :prompt, Magus.Library.Prompt do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_prompt_favorite, [:user_id, :prompt_id]
  end
end
