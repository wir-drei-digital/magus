defmodule Magus.Accounts.ApiToken do
  @moduledoc """
  Personal Access Token for the Brain HTTP API.

  Workspace-scoped (one token = one workspace; nil workspace = personal-scope).
  Plaintext is shown once at creation via the `:plaintext` metadata on the
  create result; only the SHA-256 hash and 14-char display prefix persist.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "api_tokens"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :workspace, on_delete: :delete
    end

    custom_indexes do
      index [:key_hash], unique: true
      index [:user_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :workspace_id, :scope, :expires_at, :created_via]

      change set_attribute(:user_id, actor(:id))
      change Magus.Accounts.ApiToken.Changes.GenerateSecret
    end

    update :revoke do
      accept []
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end

    update :touch_last_used_at do
      accept []
      change set_attribute(:last_used_at, &DateTime.utc_now/0)
    end

    read :list_for_actor do
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :get_by_hash do
      get? true
      argument :key_hash, :string, allow_nil?: false

      filter expr(
               key_hash == ^arg(:key_hash) and
                 is_nil(revoked_at) and
                 (is_nil(expires_at) or expires_at > now())
             )

      prepare build(load: [:user, :workspace])
    end
  end

  policies do
    policy action(:create) do
      authorize_if actor_present()
    end

    policy action([:read, :list_for_actor]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:revoke) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action([:touch_last_used_at, :get_by_hash]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string,
      allow_nil?: false,
      constraints: [max_length: 100]

    attribute :key_hash, :string,
      allow_nil?: false,
      sensitive?: true

    attribute :key_prefix, :string,
      allow_nil?: false,
      sensitive?: true

    attribute :scope, :atom,
      allow_nil?: false,
      default: :read,
      constraints: [one_of: [:read, :write]]

    attribute :last_used_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec
    attribute :revoked_at, :utc_datetime_usec

    attribute :created_via, :atom,
      allow_nil?: false,
      constraints: [one_of: [:settings, :cli_login, :oauth_session]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :workspace, Magus.Workspaces.Workspace, allow_nil?: true
  end
end
