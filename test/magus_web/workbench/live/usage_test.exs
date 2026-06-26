defmodule MagusWeb.Workbench.Live.UsageTest do
  use Magus.ResourceCase, async: true

  import Ecto.Query

  # `Usage` is the LiveView under test; the Magus.Usage domain is referenced
  # fully-qualified below to avoid the alias collision on the short name.
  alias MagusWeb.Workbench.Live.Usage

  test "compute/1 returns nil for nil user" do
    assert Usage.compute(nil) == nil
  end

  describe "compute/1" do
    setup do
      _free_plan = ensure_free_plan()
      user = create_actor()
      %{user: user}
    end

    test "returns money usage with percentage against the cap and token total", %{user: user} do
      set_sub(user,
        period_usage_cents: 300,
        monthly_spend_cap_cents: 1000
      )

      model = generate(model())
      create_usage_record(user, model, billable: true)

      data = Usage.compute(user)
      assert data.exempt == false
      assert data.spent_cents == 300
      assert data.cap_cents == 1000
      assert data.percentage == 30.0
      assert data.tokens_used == 200
      assert data.near_cap? == false
    end

    test "flags near_cap? once spend passes 80% of the cap", %{user: user} do
      set_sub(user, period_usage_cents: 850, monthly_spend_cap_cents: 1000)

      data = Usage.compute(user)
      assert data.percentage == 85.0
      assert data.near_cap? == true
    end

    test "falls back to the default cap when the user hasn't set one", %{user: user} do
      set_sub(user, period_usage_cents: 500)

      data = Usage.compute(user)
      # Default cap is 2000 cents (CHF 20) → 500/2000 = 25%.
      assert data.cap_cents == 2000
      assert data.percentage == 25.0
    end

    test "reports no cap (nil) without crashing when the user opted out", %{user: user} do
      set_sub(user, period_usage_cents: 5000, no_spend_cap: true)

      data = Usage.compute(user)
      assert data.cap_cents == nil
      assert data.percentage == 0.0
      assert data.near_cap? == false
    end

    test "free user gets the small trial allowance, flagged as trial", %{user: user} do
      # No set_sub → no Stripe subscription → trial.
      data = Usage.compute(user)
      assert data.trial == true
      assert data.cap_cents == Magus.Usage.Calculator.free_trial_spend_cap_cents()
    end

    test "threads delinquent: false for an active subscriber", %{user: user} do
      set_sub(user, period_usage_cents: 100, monthly_spend_cap_cents: 1000)

      data = Usage.compute(user)
      assert data.delinquent == false
    end

    test "flags delinquent and shows a real cap for a past_due subscriber", %{user: user} do
      set_sub(user, status: :past_due, no_spend_cap: true)

      data = Usage.compute(user)
      assert data.delinquent == true
      # The opt-out is suspended while delinquent: a concrete cap, not nil.
      assert is_integer(data.cap_cents)
      assert data.cap_cents > 0
    end

    test "exempt shape carries delinquent: false", %{user: user} do
      {:ok, _} =
        Magus.Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :exemption,
            reason: "Test exemption",
            exempt_from_limits: true
          },
          authorize?: false
        )

      data = Usage.compute(user)
      assert data.delinquent == false
    end

    test "returns an exempt shape for exempt users", %{user: user} do
      {:ok, _} =
        Magus.Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :exemption,
            reason: "Test exemption",
            exempt_from_limits: true
          },
          authorize?: false
        )

      data = Usage.compute(user)
      assert data.exempt == true
      assert data.cap_cents == nil
      assert data.percentage == 0
    end
  end

  # Sets pay-per-use fields and marks the subscription Stripe-backed (billable);
  # without a Stripe subscription the user is on the small trial allowance.
  defp set_sub(user, fields) do
    {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

    Magus.Usage.Account
    |> where([s], s.id == ^sub.id)
    |> Magus.Repo.update_all(
      set: Keyword.put_new(fields, :stripe_subscription_id, "sub_test_#{user.id}")
    )
  end
end
