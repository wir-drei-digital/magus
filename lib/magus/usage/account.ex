defmodule Magus.Usage.Account do
  @moduledoc """
  Core governance account: period usage and spend cap.

  Step A note: this resource STILL carries the Stripe columns
  (`stripe_customer_id`, `stripe_subscription_id`, `status`,
  `last_payment_status`) and Stripe-write actions (`update_subscription_from_stripe`,
  `update_payment_status`, `downgrade_to_free`, `by_stripe_subscription_id`).
  Those are the cloud-write surface to be physically split out at Step B / Phase 4.
  Core governance code does not read the Stripe columns directly: it goes through
  `Magus.Usage.BillingStatusProvider`.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Usage,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "user_subscriptions"
    repo Magus.Repo

    identity_wheres_to_sql unique_user_personal: "sponsor_user_id IS NULL",
                           unique_user_sponsor: "sponsor_user_id IS NOT NULL"
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true

    ignore_attributes [
      :inserted_at,
      :updated_at,
      :storage_usage_bytes,
      :period_usage_cents
    ]

    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "UserSubscription"
  end

  actions do
    defaults [:read]

    action :credit_status, :map do
      description "Daily credit usage snapshot for the current actor (shell indicator)."

      run fn _input, context ->
        {:ok, Magus.Usage.CreditStatus.compute(context.actor)}
      end
    end

    action :money_usage_status, :map do
      description "Pay-as-you-go spend snapshot for the current actor (shell indicator)."

      run fn _input, context ->
        # Real users carry an :id; AI-agent actors do not, and get the zero
        # snapshot (no personal billing). Mirrors the workbench mode strip's
        # `Calculator.get_money_usage_stats/1` source.
        user_id = context.actor && Map.get(context.actor, :id)
        {:ok, Magus.Usage.Calculator.get_money_usage_stats(user_id)}
      end
    end

    action :chat_feature_limits, :map do
      description "Plan feature flags for the composer (image/video generation, upload cap)."

      run fn _input, context ->
        # Mirrors MagusWeb.ChatLive.Helpers.compute_usage_state: gate the
        # image/video mode toggles client-side (the backend still enforces).
        user_id = context.actor && Map.get(context.actor, :id)
        limits = Magus.Usage.Calculator.get_effective_limits(user_id)

        result =
          if limits[:exempt] do
            %{
              image_generation_enabled: true,
              video_generation_enabled: true,
              max_upload_bytes: nil
            }
          else
            %{
              image_generation_enabled: limits[:image_generation_enabled] || false,
              video_generation_enabled: limits[:video_generation_enabled] || false,
              max_upload_bytes: limits[:max_upload_bytes]
            }
          end

        {:ok, result}
      end
    end

    action :billing_overview, :map do
      description "Subscription + spend snapshot for the SPA billing section."

      run fn _input, context ->
        user_id = context.actor && Map.get(context.actor, :id)
        {:ok, billing_overview_for(user_id)}
      end
    end

    action :set_billing_preferences, :map do
      description "Update the actor's pay-as-you-go spend cap / no-cap preference."
      argument :monthly_spend_cap_cents, :integer, allow_nil?: true
      argument :no_spend_cap, :boolean, allow_nil?: false

      run fn input, context ->
        user_id = context.actor && Map.get(context.actor, :id)

        with {:ok, sub} <- Magus.Usage.get_user_subscription(user_id, authorize?: false),
             {:ok, _updated} <-
               Magus.Usage.update_billing_preferences(
                 sub,
                 %{
                   monthly_spend_cap_cents: input.arguments.monthly_spend_cap_cents,
                   no_spend_cap: input.arguments.no_spend_cap
                 },
                 actor: context.actor
               ) do
          {:ok, billing_overview_for(user_id)}
        end
      end
    end

    read :personal_by_user_id do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and is_nil(sponsor_user_id))
      get? true
    end

    read :by_stripe_subscription_id do
      argument :stripe_subscription_id, :string, allow_nil?: false
      filter expr(stripe_subscription_id == ^arg(:stripe_subscription_id))
      get? true
    end

    create :create do
      accept [
        :user_id,
        :usage_plan_id,
        :stripe_customer_id,
        :stripe_subscription_id,
        :status,
        :current_period_start,
        :current_period_end,
        :storage_usage_bytes,
        :sponsor_user_id,
        :sponsor_org_id
      ]
    end

    update :upgrade do
      require_atomic? false

      accept [
        :usage_plan_id,
        :stripe_customer_id,
        :stripe_subscription_id,
        :status,
        :current_period_start,
        :current_period_end
      ]

      change set_attribute(:canceled_at, nil)
      change set_attribute(:last_payment_status, "succeeded")
      change Magus.Usage.Account.Changes.PropagatePlanToSponsoredSubs
    end

    update :downgrade_to_free do
      require_atomic? false

      accept [:usage_plan_id]

      change set_attribute(:stripe_subscription_id, nil)
      change set_attribute(:status, :active)
      change set_attribute(:current_period_start, nil)
      change set_attribute(:current_period_end, nil)
      change set_attribute(:canceled_at, nil)
      change set_attribute(:last_payment_status, nil)
      change Magus.Usage.Account.Changes.PropagatePlanToSponsoredSubs
    end

    update :update_from_stripe do
      require_atomic? false

      accept [
        :usage_plan_id,
        :status,
        :current_period_start,
        :current_period_end,
        :canceled_at
      ]

      change Magus.Usage.Account.Changes.PropagatePlanToSponsoredSubs
    end

    update :update_payment_status do
      accept [:last_payment_status]
    end

    update :set_sponsor_org do
      description "Set or clear the sponsoring organization for consolidated billing. nil clears (revert to personal)."
      accept [:sponsor_org_id]
    end

    update :update_sponsored_plan do
      accept [:usage_plan_id, :status]
      description "Updates the plan or status on a sponsored subscription"
    end

    update :increment_storage do
      argument :bytes, :integer, allow_nil?: false

      change atomic_update(:storage_usage_bytes, expr(storage_usage_bytes + ^arg(:bytes)))
    end

    update :decrement_storage do
      argument :bytes, :integer, allow_nil?: false

      change atomic_update(
               :storage_usage_bytes,
               expr(fragment("GREATEST(0, ? - ?)", storage_usage_bytes, ^arg(:bytes)))
             )
    end

    update :recalculate_storage do
      accept []
      require_atomic? false
      change Magus.Usage.Account.Changes.RecalculateStorageUsage
    end

    update :deduct_usage do
      description "Accrue a billable usage cost (integer CHF cents, no markup) to the postpaid period accumulator."

      argument :amount_cents, :integer, allow_nil?: false

      change atomic_update(
               :period_usage_cents,
               expr(period_usage_cents + ^arg(:amount_cents))
             )
    end

    update :update_billing_preferences do
      description "Lets a user edit their own pay-as-you-go preferences (cap, or no cap at all)."
      require_atomic? false

      accept [:monthly_spend_cap_cents, :no_spend_cap]

      validate Magus.Usage.Account.Validations.BillingPreferences
    end

    update :set_billing_interval do
      description "Sets the billing cadence (used by the PAYG migration)."
      accept [:billing_interval]
    end

    update :move_to_payg do
      description """
      Moves a paying subscription onto the pay-as-you-go model: records the
      billing cadence and switches the entitlement plan to `payg`. The base-fee
      price itself is changed in Stripe by the caller (`PaygMigration`); this is
      the local side of the cutover.
      """

      accept [:billing_interval, :usage_plan_id]
    end

    update :reset_period_usage do
      description "Zeroes the per-period usage mirror at a cycle boundary or on activation."
      change set_attribute(:period_usage_cents, 0)
    end

    update :set_extra_seats do
      accept [:extra_seats]
      require_atomic? false

      validate fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :extra_seats) do
          n when is_integer(n) and n >= 0 -> :ok
          _ -> {:error, field: :extra_seats, message: "must be a non-negative integer"}
        end
      end
    end
  end

  policies do
    # Computes only from the actor; nothing to leak across users.
    policy action(:credit_status) do
      authorize_if actor_present()
    end

    # Computes only from the actor's own subscription; nothing to leak.
    policy action(:money_usage_status) do
      authorize_if actor_present()
    end

    # Computes only from the actor's own plan; nothing to leak.
    policy action(:chat_feature_limits) do
      authorize_if actor_present()
    end

    # Read/update only the actor's own subscription (overview reads via the
    # actor's own user_id; set_billing_preferences updates via the owner bypass).
    policy action([:billing_overview, :set_billing_preferences]) do
      authorize_if actor_present()
    end

    # Owners may edit their own billing preferences. A passing bypass authorizes
    # and skips the admin-only update policy below; a non-owner falls through to
    # it (so admins are still covered).
    bypass action(:update_billing_preferences) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Users can read their own subscription
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    # System operations (webhooks, registration) bypass auth
    policy action_type(:create) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:update) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :stripe_customer_id, :string do
      allow_nil? true
      description "Stripe Customer ID"
    end

    attribute :stripe_subscription_id, :string do
      allow_nil? true
      description "Stripe Subscription ID"
    end

    attribute :status, :atom do
      constraints one_of: [:active, :past_due, :canceled, :incomplete, :trialing]
      allow_nil? false
      default :active
      public? true
      description "Current subscription status"
    end

    attribute :current_period_start, :utc_datetime_usec do
      allow_nil? true
      description "Billing period start"
    end

    attribute :current_period_end, :utc_datetime_usec do
      allow_nil? true
      description "Billing period end"
    end

    attribute :canceled_at, :utc_datetime_usec do
      allow_nil? true
      description "When subscription was canceled"
    end

    attribute :last_payment_status, :string do
      allow_nil? true
      public? true
      description "Last payment status for UI banners: succeeded, failed, etc."
    end

    attribute :storage_usage_bytes, :integer do
      allow_nil? false
      default 0
      public? true
      description "Cached storage usage, updated on file create/delete"
    end

    attribute :sponsor_user_id, :uuid do
      allow_nil? true
      public? false

      description "When set, this is a sponsored subscription paid for by the sponsor user. nil = personal subscription."
    end

    attribute :sponsor_org_id, :uuid do
      allow_nil? true
      public? false

      description "When set, this account's seat + usage bill to the given organization (org-consolidated billing). nil = personal billing."
    end

    attribute :extra_seats, :integer do
      allow_nil? false
      default 0
      public? true

      description "Additional paid seats beyond the plan's included `sponsorable_seats`. Only meaningful on personal subscriptions (sponsor_user_id == nil)."
    end

    attribute :stripe_subscription_item_id, :string do
      allow_nil? true
      description "Stripe subscription item representing the per-seat add-on line."
    end

    # --- Pay-as-you-go billing (base fee + pay-as-you-go usage) ---

    attribute :billing_interval, :atom do
      allow_nil? false
      default :monthly
      public? true
      constraints one_of: [:monthly, :annual]
      description "Cadence of the base-fee Stripe subscription."
    end

    attribute :period_usage_cents, :integer do
      allow_nil? false
      default 0
      public? true

      description "Postpaid metered accumulator in integer cents (CHF): billable usage this period. Reset at period close."
    end

    attribute :monthly_spend_cap_cents, :integer do
      allow_nil? true
      public? true

      description "User-set hard monthly spend cap in integer cents (CHF). nil = base only / no overage."
    end

    attribute :no_spend_cap, :boolean do
      allow_nil? false
      default false
      public? true

      description "When true, usage is never blocked by a spend cap — the user pays exactly what they use, billed with the monthly invoice (postpaid)."
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :usage_plan, Magus.Usage.Policy do
      allow_nil? false
    end

    belongs_to :sponsor, Magus.Accounts.User do
      source_attribute :sponsor_user_id
      destination_attribute :id
      allow_nil? true
      public? false
      define_attribute? false
    end

    belongs_to :sponsor_org, Magus.Organizations.Organization do
      source_attribute :sponsor_org_id
      destination_attribute :id
      allow_nil? true
      public? false
      define_attribute? false
    end
  end

  calculations do
    calculate :is_premium?, :boolean do
      description "User has premium access: active or canceled but still in period"

      calculation expr(
                    status == :active or
                      (status == :canceled and current_period_end > now())
                  )
    end
  end

  identities do
    # Personal subscription: one per user where sponsor_user_id is null
    identity :unique_user_personal, [:user_id], where: expr(is_nil(sponsor_user_id))
    # Sponsored subscription: one per (recipient, sponsor) pair
    identity :unique_user_sponsor, [:user_id, :sponsor_user_id],
      where: expr(not is_nil(sponsor_user_id))
  end

  # --- Billing overview helpers (SPA billing section) ---

  defp billing_overview_for(nil), do: empty_billing_overview()

  defp billing_overview_for(user_id) do
    case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
      {:ok, sub} ->
        plan = load_plan_tolerantly(sub)
        money = Magus.Usage.Calculator.get_money_usage_stats(user_id)

        %{
          plan_key: plan[:key],
          plan_name: plan[:name],
          status: to_string(sub.status),
          current_period_end: iso_or_nil(sub.current_period_end),
          last_payment_status: sub.last_payment_status,
          no_spend_cap: sub.no_spend_cap || false,
          monthly_spend_cap_cents: sub.monthly_spend_cap_cents,
          spent_cents: money.spent_cents,
          cap_cents: money.cap_cents,
          default_cap_cents: Magus.Usage.Calculator.default_spend_cap_cents(),
          tokens_used: money.tokens_used,
          delinquent: money.delinquent,
          exempt: money.exempt,
          is_payg: plan[:key] == "payg",
          billing_edition: Magus.Usage.billing_edition?()
        }

      _ ->
        empty_billing_overview()
    end
  end

  defp empty_billing_overview do
    %{
      plan_key: nil,
      plan_name: nil,
      status: "none",
      current_period_end: nil,
      last_payment_status: nil,
      no_spend_cap: false,
      monthly_spend_cap_cents: nil,
      spent_cents: 0,
      cap_cents: nil,
      default_cap_cents: Magus.Usage.Calculator.default_spend_cap_cents(),
      tokens_used: 0,
      delinquent: false,
      exempt: false,
      is_payg: false,
      billing_edition: Magus.Usage.billing_edition?()
    }
  end

  # Loaded separately + tolerantly: a stale/unmigrated usage_plans row would
  # otherwise nil the whole overview.
  defp load_plan_tolerantly(sub) do
    case Ash.load(sub, [:usage_plan], authorize?: false) do
      {:ok, %{usage_plan: %{} = plan}} -> %{key: plan.key, name: plan.name}
      _ -> %{key: nil, name: nil}
    end
  rescue
    _ -> %{key: nil, name: nil}
  end

  defp iso_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_or_nil(_), do: nil
end
