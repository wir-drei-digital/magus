defmodule Magus.Usage.Policy do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Usage,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "usage_plans"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    read :active_plans do
      description "Get all active plans available for new subscriptions"
      filter expr(is_active == true)
      prepare build(sort: [sort_order: :asc])
    end

    read :free_plan do
      description "Get the free plan"
      filter expr(key == "free")
      get? true
    end

    read :by_stripe_price_id do
      description "Get a plan by its Stripe price ID (monthly or yearly)"
      argument :stripe_price_id, :string, allow_nil?: false
      get? true

      filter expr(
               stripe_price_id_monthly == ^arg(:stripe_price_id) or
                 stripe_price_id_yearly == ^arg(:stripe_price_id)
             )
    end

    create :create do
      accept [
        :key,
        :name,
        :description,
        :price_monthly_cents,
        :stripe_price_id_monthly,
        :stripe_price_id_yearly,
        :storage_bytes,
        :max_upload_bytes,
        :is_active,
        :sort_order,
        :max_routing_tier,
        :image_generation_enabled,
        :video_generation_enabled,
        :sponsorable_seats,
        :extra_seat_stripe_price_id
      ]
    end

    update :update do
      accept [
        :name,
        :description,
        :price_monthly_cents,
        :stripe_price_id_monthly,
        :stripe_price_id_yearly,
        :storage_bytes,
        :max_upload_bytes,
        :is_active,
        :sort_order,
        :max_routing_tier,
        :image_generation_enabled,
        :video_generation_enabled,
        :sponsorable_seats,
        :extra_seat_stripe_price_id
      ]
    end
  end

  policies do
    # Anyone can read plans (needed for pricing page)
    policy action_type(:read) do
      authorize_if always()
    end

    # Only admins can create/update plans
    policy action_type(:create) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:update) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      description "Unique identifier: free, starter, pro, pro-v2, etc."
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Display name"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Plan description"
    end

    attribute :price_monthly_cents, :integer do
      allow_nil? false
      default 0
      public? true
      description "Display price only - Stripe is source of truth for billing"
    end

    attribute :stripe_price_id_monthly, :string do
      allow_nil? true
      description "Stripe Price ID for monthly billing"
    end

    attribute :stripe_price_id_yearly, :string do
      allow_nil? true
      description "Stripe Price ID for annual billing (future)"
    end

    attribute :storage_bytes, :integer do
      allow_nil? false
      default 0
      public? true
      description "Total storage limit in bytes"
    end

    attribute :max_upload_bytes, :integer do
      allow_nil? false
      default 0
      public? true
      description "Max single file upload size in bytes"
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true

      description "Whether new users can subscribe to this plan. Legacy users can stay on inactive plans."
    end

    attribute :max_routing_tier, :atom do
      allow_nil? false
      default :simple
      public? true
      constraints one_of: [:simple, :standard, :complex]

      description "Maximum routing tier for auto-routing. Controls which model complexity tier users on this plan can access."
    end

    attribute :image_generation_enabled, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether users on this plan can generate images"
    end

    attribute :video_generation_enabled, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether users on this plan can generate videos"
    end

    attribute :sponsorable_seats, :integer do
      allow_nil? true
      public? true

      description "Number of sponsored seats included with this plan. `nil` or `0` means the user cannot sponsor seats; positive integer means included sponsored seats; combined with `extra_seats` on the personal subscription for the cap."
    end

    attribute :extra_seat_stripe_price_id, :string do
      allow_nil? true
      public? true

      description "Stripe price ID for add-on seats beyond `sponsorable_seats`. `nil` means add-on seats are not offered on this plan."
    end

    attribute :sort_order, :integer do
      allow_nil? false
      default 0
      public? true
      description "Display order on pricing page"
    end

    timestamps()
  end

  relationships do
    # Pin the FK explicitly: Ash infers the destination attribute from this
    # resource's short name, so after the UsagePlan -> Policy rename it would
    # otherwise look for `policy_id`. The column is still `usage_plan_id`.
    has_many :subscriptions, Magus.Usage.Account do
      destination_attribute :usage_plan_id
    end
  end

  identities do
    identity :unique_key, [:key]
  end
end
