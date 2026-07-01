defmodule Magus.Organizations.Organization do
  @moduledoc """
  A billing organization. Owns a Stripe customer + subscription (ids written
  by the cloud edition; opaque strings here) and consolidates member billing.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Organizations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "organizations"
    repo Magus.Repo
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    belongs_to_actor :owner, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "Organization"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :slug]
      change relate_actor(:owner)
      change Magus.Organizations.Organization.Changes.CreateOwnerMember
    end

    update :update do
      accept [:name]
    end

    update :set_billing do
      description "Cloud-written Stripe linkage + billing status. Not for end users."

      accept [
        :billing_interval,
        :billing_status,
        :stripe_customer_id,
        :stripe_subscription_id,
        :stripe_subscription_item_id,
        :current_period_start,
        :current_period_end
      ]

      require_atomic? false
    end
  end

  policies do
    bypass action(:set_billing) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(exists(members, status == :active and user_id == ^actor(:id)))
    end

    policy action_type(:update) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/, min_length: 2, max_length: 64
    end

    attribute :billing_interval, :atom do
      allow_nil? false
      default :monthly
      constraints one_of: [:monthly, :annual]
      public? true
    end

    attribute :billing_status, :atom do
      allow_nil? false
      default :active
      constraints one_of: [:active, :past_due, :canceled, :incomplete, :trialing]
      public? true
    end

    attribute :stripe_customer_id, :string, allow_nil?: true, public?: false
    attribute :stripe_subscription_id, :string, allow_nil?: true, public?: false
    attribute :stripe_subscription_item_id, :string, allow_nil?: true, public?: false
    attribute :current_period_start, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :current_period_end, :utc_datetime_usec, allow_nil?: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :owner, Magus.Accounts.User do
      allow_nil? false
      public? true
    end

    has_many :members, Magus.Organizations.OrganizationMember do
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
