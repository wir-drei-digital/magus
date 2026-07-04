defmodule Magus.Models.OpenRouterProvider do
  @moduledoc """
  A synced OpenRouter upstream provider and the admin decision to allow it.

  Metadata (`name`, `headquarters`, `datacenters`, policy URLs) is refreshed
  from `GET /api/v1/providers` by `Magus.Models.OpenRouterProviderSync`.
  `headquarters`/`datacenters` are ISO 3166-1 alpha-2 codes shown to the
  admin as advisory context; they are never used for automatic enforcement.
  `allowed` is the admin decision and is deliberately left untouched by
  resync (see `:upsert` `upsert_fields`). New providers default to
  `allowed: false` (fail closed).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Models,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "open_router_providers"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    read :allowed do
      description "Providers the admin has allowed."
      filter expr(allowed == true)
    end

    read :by_slug do
      get_by :slug
    end

    create :upsert do
      description "Insert or refresh a provider from the OpenRouter API. Never changes `allowed`."
      upsert? true
      upsert_identity :slug

      upsert_fields [
        :name,
        :headquarters,
        :datacenters,
        :privacy_policy_url,
        :terms_of_service_url,
        :status_page_url,
        :last_synced_at
      ]

      accept [
        :slug,
        :name,
        :headquarters,
        :datacenters,
        :privacy_policy_url,
        :terms_of_service_url,
        :status_page_url,
        :last_synced_at
      ]
    end

    update :set_allowed do
      description "Admin toggles whether this provider may serve requests."
      accept [:allowed]
    end
  end

  policies do
    # The sync path reads without an actor via authorize?: false and bypasses
    # these policies (mirrors Magus.Models.Provider). Admin UI passes an actor.
    policy action_type(:read) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type([:create, :update]) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :slug, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :headquarters, :string, public?: true
    attribute :datacenters, {:array, :string}, allow_nil?: false, default: [], public?: true
    attribute :privacy_policy_url, :string, public?: true
    attribute :terms_of_service_url, :string, public?: true
    attribute :status_page_url, :string, public?: true

    attribute :allowed, :boolean, allow_nil?: false, default: false, public?: true

    attribute :last_synced_at, :utc_datetime, public?: true

    timestamps()
  end

  identities do
    identity :slug, [:slug]
  end
end
