defmodule Magus.Usage.UsageCalculatorTest do
  use Magus.ResourceCase, async: true

  import Ecto.Query

  alias Magus.Usage
  alias Magus.Usage.Calculator

  require Ash.Query

  describe "get_effective_limits/1" do
    setup do
      # ensure_free_plan must be called before create_actor
      # because create_actor (user registration) now automatically creates a free subscription
      free_plan = ensure_free_plan()
      user = create_actor()

      %{user: user, free_plan: free_plan}
    end

    test "returns plan limits for user with subscription", %{user: user, free_plan: plan} do
      limits = Calculator.get_effective_limits(user.id)

      assert limits.exempt == false
      assert limits.storage_bytes == plan.storage_bytes
      assert limits.max_upload_bytes == plan.max_upload_bytes
    end

    # Note: Users without subscriptions are no longer possible since Phase 7
    # All users automatically get a free subscription on registration.

    test "adds storage bonus from override", %{user: user, free_plan: plan} do
      # Create a bonus override
      {:ok, _override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Test bonus",
            bonus_storage_bytes: 50
          },
          authorize?: false
        )

      limits = Calculator.get_effective_limits(user.id)

      assert limits.exempt == false
      assert limits.storage_bytes == plan.storage_bytes + 50
    end

    test "returns exempt for user with exemption override", %{user: user} do
      {:ok, _override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :exemption,
            reason: "Test exemption",
            exempt_from_limits: true
          },
          authorize?: false
        )

      limits = Calculator.get_effective_limits(user.id)

      assert limits.exempt == true
    end

    test "ignores expired overrides", %{user: user, free_plan: plan} do
      # Create an expired override
      expired_at = DateTime.add(DateTime.utc_now(), -1, :day)

      {:ok, _override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Expired bonus",
            bonus_storage_bytes: 1000,
            expires_at: expired_at
          },
          authorize?: false
        )

      limits = Calculator.get_effective_limits(user.id)

      # Should not include the expired bonus
      assert limits.storage_bytes == plan.storage_bytes
    end
  end

  describe "get_storage_used/1" do
    setup do
      # ensure_free_plan must be called before create_actor
      _free_plan = ensure_free_plan()
      user = create_actor()
      %{user: user}
    end

    test "returns 0 for new user with fresh subscription", %{user: user} do
      storage = Calculator.get_storage_used(user.id)
      assert storage == 0
    end

    test "returns cached storage from subscription", %{user: user} do
      # Increment storage usage
      Usage.increment_storage_usage(user.id, 1_000_000, authorize?: false)

      storage = Calculator.get_storage_used(user.id)
      assert storage == 1_000_000
    end
  end

  describe "get_spend_state/1" do
    setup do
      _free_plan = ensure_free_plan()
      user = create_actor()
      %{user: user, default_cap: Calculator.default_spend_cap_cents()}
    end

    test "nil user_id returns a zero state with a zero cap (blocked)" do
      assert %{
               exempt: false,
               period_usage_cents: 0,
               effective_cap_cents: 0
             } = Calculator.get_spend_state(nil)
    end

    test "fresh free subscription gets the trial allowance, flagged as trial", %{user: user} do
      trial_cap = Calculator.free_trial_spend_cap_cents()

      assert %{
               exempt: false,
               trial: true,
               period_usage_cents: 0,
               effective_cap_cents: ^trial_cap
             } = Calculator.get_spend_state(user.id)
    end

    test "subscribed user without an own cap gets the default cap", %{
      user: user,
      default_cap: cap
    } do
      subscribe(user.id)

      assert %{
               exempt: false,
               trial: false,
               period_usage_cents: 0,
               effective_cap_cents: ^cap
             } = Calculator.get_spend_state(user.id)
    end

    test "reflects period usage and a user-set cap", %{user: user} do
      subscribe(user.id)

      set_sub_fields(user.id,
        period_usage_cents: 120,
        monthly_spend_cap_cents: 1000
      )

      state = Calculator.get_spend_state(user.id)
      assert state.period_usage_cents == 120
      assert state.effective_cap_cents == 1000
    end

    test "no_spend_cap is surfaced in the spend state for subscribers", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, no_spend_cap: true)

      assert %{no_spend_cap: true} = Calculator.get_spend_state(user.id)
    end

    test "no_spend_cap is ignored for free (trial) users", %{user: user} do
      set_sub_fields(user.id, no_spend_cap: true)

      assert %{no_spend_cap: false, trial: true} = Calculator.get_spend_state(user.id)
    end

    test "marks a past_due billable sub delinquent and ignores no_spend_cap", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :past_due, no_spend_cap: true)

      state = Calculator.get_spend_state(user.id)
      assert state.delinquent == true
      assert state.no_spend_cap == false
    end

    test "an active billable sub is not delinquent and keeps no_spend_cap", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :active, no_spend_cap: true)

      state = Calculator.get_spend_state(user.id)
      assert state.delinquent == false
      assert state.no_spend_cap == true
    end

    test "a trialing billable sub is not delinquent", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :trialing, no_spend_cap: true)

      state = Calculator.get_spend_state(user.id)
      assert state.delinquent == false
      assert state.no_spend_cap == true
    end

    test "a free (non-billable) sub is never delinquent regardless of status", %{user: user} do
      set_sub_fields(user.id, status: :past_due)

      state = Calculator.get_spend_state(user.id)
      assert state.delinquent == false
      assert state.trial == true
    end

    test "zero state (nil user) is not delinquent" do
      assert %{delinquent: false} = Calculator.get_spend_state(nil)
    end

    test "exemption override sets exempt: true", %{user: user} do
      {:ok, _} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :exemption,
            reason: "Test exemption",
            exempt_from_limits: true
          },
          authorize?: false
        )

      assert %{exempt: true} = Calculator.get_spend_state(user.id)
    end

    test "remaining_allowance_cents = headroom under the cap", %{user: user} do
      subscribe(user.id)

      set_sub_fields(user.id,
        period_usage_cents: 700,
        monthly_spend_cap_cents: 1000
      )

      state = Calculator.get_spend_state(user.id)
      # (1000 - 700) headroom
      assert Calculator.remaining_allowance_cents(state) == 300
      assert Calculator.period_spend_cents(state) == 700
    end
  end

  describe "get_money_usage_stats/1" do
    setup do
      _free_plan = ensure_free_plan()
      user = create_actor()
      %{user: user}
    end

    test "zero state (nil user) is not delinquent" do
      assert %{delinquent: false} = Calculator.get_money_usage_stats(nil)
    end

    test "an active no_spend_cap billable sub is not delinquent and shows no cap (nil)",
         %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :active, no_spend_cap: true)

      stats = Calculator.get_money_usage_stats(user.id)
      assert stats.delinquent == false
      assert stats.cap_cents == nil
    end

    test "a past_due no_spend_cap billable sub is delinquent and shows a real cap (not unlimited)",
         %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :past_due, no_spend_cap: true)

      stats = Calculator.get_money_usage_stats(user.id)
      assert stats.delinquent == true
      # The no_spend_cap opt-out is suspended while delinquent: the displayed cap
      # must be a concrete number, never nil ("no cap / unlimited").
      assert is_integer(stats.cap_cents)
      assert stats.cap_cents > 0
    end
  end

  # Directly set pay-per-use fields on the personal subscription (see
  # LimitEnforcerTest for the rationale).
  defp set_sub_fields(user_id, fields) do
    Usage.Account
    |> where([s], s.user_id == ^user_id and is_nil(s.sponsor_org_id))
    |> Magus.Repo.update_all(set: fields)
  end

  # Mark the personal subscription as Stripe-backed (billable); free users get
  # the trial allowance instead of the user-set/default caps.
  defp subscribe(user_id) do
    set_sub_fields(user_id, stripe_subscription_id: "sub_test_#{user_id}")
  end
end
