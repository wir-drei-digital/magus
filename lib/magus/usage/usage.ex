defmodule Magus.Usage do
  @moduledoc """
  Usage governance: usage plans, daily credits, token/cost metering, and the
  per-user billing-status columns the rest of the app reads. This is the
  open-core governance layer: it owns the data and policy without naming
  `Magus.Billing`, which the combined/cloud edition wires in behind seams
  (`Magus.Usage.MeteringSink`, `Magus.Usage.AccountLifecycle`,
  `Magus.Usage.ExchangeRate`).
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPaperTrail.Domain, AshTypescript.Rpc]

  paper_trail do
    include_versions? true
  end

  typescript_rpc do
    # Shell credit indicator: daily usage snapshot for the current actor.
    resource Magus.Usage.Account do
      rpc_action :credit_status, :credit_status
      # Pay-as-you-go spend snapshot (spent/cap/tokens/delinquent).
      rpc_action :money_usage_status, :money_usage_status
      # Composer mode gating: image/video generation enabled + upload cap.
      rpc_action :chat_feature_limits, :chat_feature_limits
      # Billing section: subscription overview + spend-cap preferences.
      rpc_action :billing_overview, :billing_overview
      rpc_action :set_billing_preferences, :set_billing_preferences
    end
  end

  resources do
    resource Magus.Usage.Policy do
      define :create_usage_plan, action: :create
      define :update_usage_plan, action: :update
      define :get_usage_plan, action: :read, get_by: [:id]
      define :get_plan_by_key, action: :read, get_by: [:key]
      define :get_free_plan, action: :free_plan
      define :list_active_plans, action: :active_plans
      define :get_plan_by_stripe_price_id, action: :by_stripe_price_id, args: [:stripe_price_id]
    end

    resource Magus.Usage.Account do
      define :create_user_subscription, action: :create
      define :get_user_subscription, action: :personal_by_user_id, args: [:user_id]

      define :get_subscription_by_stripe_id,
        action: :by_stripe_subscription_id,
        args: [:stripe_subscription_id]

      define :upgrade_subscription, action: :upgrade
      define :downgrade_to_free, action: :downgrade_to_free
      define :update_subscription_from_stripe, action: :update_from_stripe
      define :update_payment_status, action: :update_payment_status
      define :set_sponsor_org, action: :set_sponsor_org

      define :increment_storage_usage,
        action: :increment_storage,
        args: [:bytes],
        get_by: [:user_id]

      define :decrement_storage_usage,
        action: :decrement_storage,
        args: [:bytes],
        get_by: [:user_id]

      define :recalculate_storage, action: :recalculate_storage
      define :set_extra_seats, action: :set_extra_seats

      define :deduct_usage,
        action: :deduct_usage,
        args: [:amount_cents],
        get_by: [:user_id]

      define :reset_period_usage, action: :reset_period_usage

      define :update_billing_preferences, action: :update_billing_preferences
      define :set_billing_interval, action: :set_billing_interval
      define :move_to_payg, action: :move_to_payg
    end

    resource Magus.Usage.Override do
      define :create_usage_override, action: :create
      define :update_usage_override, action: :update
      define :delete_usage_override, action: :destroy
      define :list_active_overrides_for_user, action: :active_for_user, args: [:user_id]
    end

    resource Magus.Usage.MessageUsage do
      define :create_message_usage, action: :create
      define :record_message_usage, action: :record_from_response
    end
  end

  @doc """
  Whether the commercial billing edition is present.

  Distinct from `Magus.Usage.MeteringSink.configured?/0` (which only reports that
  *metering* is wired): this is the explicit "commercial edition active" signal
  that core uses to gate billing-only UI (e.g. price fields in the plans admin)
  without naming `Magus.Billing`. The combined/cloud app sets
  `config :magus, :billing_edition?, true`; a pure OSS install leaves it false.
  """
  @spec billing_edition?() :: boolean()
  def billing_edition?, do: Application.get_env(:magus, :billing_edition?, false)

  @doc """
  Resolve the free plan and downgrade `account` to it. Convenience over
  `get_free_plan/1` + `downgrade_to_free/3` for billing revert/cancel paths.
  Returns the downgrade result, or `{:error, :no_free_plan}` when no free plan
  is configured.
  """
  def downgrade_to_free_plan(account, opts \\ []) do
    case get_free_plan(opts) do
      {:ok, free} when not is_nil(free) ->
        downgrade_to_free(account, %{usage_plan_id: free.id}, opts)

      _ ->
        {:error, :no_free_plan}
    end
  end
end
