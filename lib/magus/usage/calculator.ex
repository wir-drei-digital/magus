defmodule Magus.Usage.Calculator do
  @moduledoc """
  Calculates current usage against plan limits.

  Provides functions to:
  - Get effective limits for a user (plan limits + storage bonuses from overrides)
  - Get PAYG spend state for enforcement and UI
  - Get cached storage usage
  """

  require Ash.Query

  @no_subscription_limits %{
    storage_bytes: 0,
    max_upload_bytes: 0,
    image_generation_enabled: false,
    video_generation_enabled: false,
    sponsorable_seats: nil,
    exempt: false
  }

  @doc """
  Returns the platform default monthly spend cap (integer cents, CHF).

  Applied to pay-per-use overage when a user has not set their own
  `monthly_spend_cap_cents`. A nil cap on the subscription means "use this
  default", not "unlimited".
  """
  def default_spend_cap_cents do
    Application.get_env(:magus, :default_monthly_spend_cap_cents, 2000)
  end

  @doc """
  Returns the free-plan trial spend allowance (integer cents, CHF).

  Users without a billable (Stripe-backed) subscription get this tiny
  allowance instead of the default cap, so they can try the full harness —
  roughly fifty typical chat messages — at a cost to us of practically nothing.
  Their usage can never be invoiced, so the allowance does not reset; it is a
  one-time trial budget.
  """
  def free_trial_spend_cap_cents do
    Application.get_env(:magus, :free_trial_spend_cap_cents, 50)
  end

  @doc """
  Returns the effective limits for a user, combining their plan limits with any active overrides.

  Returns `%{exempt: true}` if user has an exemption override.
  Returns `%{exempt: false, ...}` otherwise.

  Limits set to `nil` mean unlimited.
  """
  def get_effective_limits(nil) do
    require Logger

    Logger.warning(
      "get_effective_limits/1 called with nil user_id, returning no-subscription limits"
    )

    @no_subscription_limits
  end

  def get_effective_limits(user_id) do
    all_subscriptions =
      Magus.Usage.Account
      |> Ash.Query.filter(
        user_id == ^user_id and
          status in [:active, :trialing]
      )
      |> Ash.Query.load(:usage_plan)
      |> Ash.read(authorize?: false)

    case all_subscriptions do
      {:ok, []} ->
        require Logger

        Logger.warning(
          "No active subscription for user #{user_id}, returning no-subscription limits"
        )

        @no_subscription_limits

      {:ok, subscriptions} ->
        sponsored = Enum.filter(subscriptions, &(not is_nil(&1.sponsor_user_id)))

        subscription =
          if sponsored != [] do
            Enum.max_by(sponsored, fn sub ->
              routing_tier_rank(sub.usage_plan.max_routing_tier)
            end)
          else
            Enum.find(subscriptions, fn sub -> is_nil(sub.sponsor_user_id) end) ||
              hd(subscriptions)
          end

        calculate_limits(subscription)

      {:error, reason} ->
        require Logger

        Logger.warning("Failed to load subscriptions for user #{user_id}: #{inspect(reason)}")

        @no_subscription_limits
    end
  end

  @doc """
  Returns effective limits from an already-loaded subscription (avoids redundant DB lookup).
  """
  def get_effective_limits_from_subscription(subscription) do
    calculate_limits(subscription)
  end

  defp calculate_limits(subscription) do
    plan = subscription.usage_plan

    # Get any active overrides
    {:ok, overrides} =
      Magus.Usage.list_active_overrides_for_user(subscription.user_id, authorize?: false)

    # Check for exemption
    if Enum.any?(overrides, & &1.exempt_from_limits) do
      %{exempt: true}
    else
      bonus_storage = sum_bonuses(overrides, :bonus_storage_bytes)

      %{
        storage_bytes: plan.storage_bytes + bonus_storage,
        max_upload_bytes: plan.max_upload_bytes,
        image_generation_enabled: plan.image_generation_enabled,
        video_generation_enabled: plan.video_generation_enabled,
        sponsorable_seats: plan.sponsorable_seats,
        exempt: false
      }
    end
  end

  defp sum_bonuses(overrides, field) do
    overrides
    |> Enum.map(&(Map.get(&1, field) || 0))
    |> Enum.sum()
  end

  defp routing_tier_rank(:complex), do: 3
  defp routing_tier_rank(:standard), do: 2
  defp routing_tier_rank(:simple), do: 1
  defp routing_tier_rank(_), do: 0

  @doc """
  Returns the pay-per-use spend state for a user, used by the money-based
  enforcement gate.

  Reads the personal subscription's period accumulator (maintained by
  `Account.deduct_usage`) and resolves the effective monthly cap.
  Billable (Stripe-backed) subscriptions use `monthly_spend_cap_cents` or the
  platform default; free users get the small trial allowance instead (their
  usage can never be invoiced) and their `no_spend_cap` preference is ignored.
  Exemptions bypass.

  Returns a map:

      %{
        exempt: boolean(),
        trial: boolean(),
        delinquent: boolean(),
        no_spend_cap: boolean(),
        period_usage_cents: non_neg_integer(),
        effective_cap_cents: non_neg_integer()
      }

  `delinquent` is true when the subscription is billable (Stripe-backed) but not
  in good standing (`status` not in `[:active, :trialing]` — e.g. `past_due`).
  A delinquent subscription gets no new postpaid spend and its `no_spend_cap`
  opt-out is suspended.

  When the user has no subscription, returns a zero-usage state
  with a **zero** cap — no subscription means no pay-per-use allowance.
  """
  def get_spend_state(nil), do: zero_spend_state()

  def get_spend_state(user_id) do
    case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
      {:ok, subscription} ->
        exempt = exempt?(user_id)
        billable = billable?(subscription)
        # Align with `get_effective_limits`: only active/trialing subscriptions
        # are in good standing. A billable subscription that is NOT active is
        # delinquent (e.g. `past_due` during the dunning window): it gets no new
        # postpaid spend and its `no_spend_cap` opt-out is suspended — only the
        # only the spend cap remains. Billing status is resolved through the
        # provider seam; its Default reads the same `status` column, so behavior
        # is identical (cloud edition later reads live from Stripe).
        active =
          Magus.Usage.BillingStatusProvider.status_for_user(user_id) in [:active, :trialing]

        delinquent = billable and not active

        %{
          exempt: exempt,
          trial: not billable,
          delinquent: delinquent,
          no_spend_cap: billable and active and (subscription.no_spend_cap || false),
          period_usage_cents: subscription.period_usage_cents || 0,
          effective_cap_cents: effective_cap_cents(subscription)
        }

      {:error, _} ->
        zero_spend_state()
    end
  end

  @doc "Money spent (postpaid accrual) so far this period, in integer cents."
  def period_spend_cents(%{period_usage_cents: cents}), do: cents || 0
  def period_spend_cents(_), do: 0

  @period_lookback_days 30

  @doc """
  Money-denominated usage stats for the UI indicator: spend this period, the
  effective cap, and tokens used this period (all in CHF cents
  except `tokens_used`). No subscription ⇒ a zero state.
  """
  def get_money_usage_stats(nil), do: zero_money_stats()

  def get_money_usage_stats(user_id) do
    case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
      {:ok, sub} ->
        billable = billable?(sub)
        # Mirror `get_spend_state`: a billable sub that is not active/trialing is
        # delinquent (e.g. `past_due`). Resolve status through the same
        # BillingStatusProvider seam as enforcement, so the display cannot diverge
        # from the gate once a cloud provider reads live billing status rather
        # than the cached `status` column.
        active =
          Magus.Usage.BillingStatusProvider.status_for_user(user_id) in [:active, :trialing]

        delinquent = billable and not active

        %{
          exempt: exempt?(user_id),
          trial: not billable,
          delinquent: delinquent,
          spent_cents: sub.period_usage_cents || 0,
          # Only treat `no_spend_cap` as uncapped while the sub is billable AND in
          # good standing. A delinquent opt-out user must NOT see "no cap": their
          # postpaid spend is suspended, so we show the concrete fallback cap.
          cap_cents:
            if(billable and active and sub.no_spend_cap, do: nil, else: effective_cap_cents(sub)),
          tokens_used: period_tokens_used(user_id, period_start_for(sub))
        }

      {:error, _} ->
        zero_money_stats()
    end
  end

  @doc "Sum of billable `total_tokens` for the user since `since`."
  def period_tokens_used(user_id, %DateTime{} = since) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(
      user_id == ^user_id and
        billable == true and
        inserted_at >= ^since
    )
    |> Ash.sum!(:total_tokens, authorize?: false) || 0
  end

  defp period_start_for(%{current_period_start: %DateTime{} = start}), do: start
  defp period_start_for(_), do: DateTime.add(DateTime.utc_now(), -@period_lookback_days, :day)

  defp zero_money_stats do
    %{
      exempt: false,
      trial: false,
      delinquent: false,
      spent_cents: 0,
      cap_cents: 0,
      tokens_used: 0
    }
  end

  @doc """
  Remaining pay-per-use allowance in integer cents: headroom left under the
  effective cap. Never negative.
  """
  def remaining_allowance_cents(%{period_usage_cents: used, effective_cap_cents: cap}) do
    max(0, cap - (used || 0))
  end

  # Resolve the effective cap. Only billable (Stripe-backed) subscriptions get
  # the user-set cap / platform default — their overage lands on an invoice.
  # Anyone else gets the free trial allowance: usage that can't be invoiced
  # must stay at "costs us practically nothing".
  defp effective_cap_cents(subscription) do
    cond do
      not billable?(subscription) -> free_trial_spend_cap_cents()
      is_integer(subscription.monthly_spend_cap_cents) -> subscription.monthly_spend_cap_cents
      true -> default_spend_cap_cents()
    end
  end

  # An org-sponsored account is billable via the org's subscription even though
  # it has no personal Stripe subscription id. A personal account is billable
  # once it carries a Stripe subscription id.
  defp billable?(%{sponsor_org_id: org_id}) when is_binary(org_id), do: true
  defp billable?(%{stripe_subscription_id: id}), do: is_binary(id) and id != ""
  defp billable?(_), do: false

  defp exempt?(user_id) do
    case Magus.Usage.list_active_overrides_for_user(user_id, authorize?: false) do
      {:ok, overrides} -> Enum.any?(overrides, & &1.exempt_from_limits)
      _ -> false
    end
  end

  defp zero_spend_state do
    %{
      exempt: false,
      trial: false,
      delinquent: false,
      no_spend_cap: false,
      period_usage_cents: 0,
      effective_cap_cents: 0
    }
  end

  @doc """
  Gets the cached storage usage for a user from their subscription.

  This is updated atomically on file create/delete to avoid expensive
  SUM queries on every upload.
  """
  def get_storage_used(user_id) do
    case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
      {:ok, subscription} -> subscription.storage_usage_bytes
      {:error, _} -> 0
    end
  end

  @doc """
  Returns current usage stats for a user.

  Useful for displaying in UI.
  """
  def get_usage_stats(user_id, _timezone) do
    %{
      storage_used: get_storage_used(user_id)
    }
  end
end
