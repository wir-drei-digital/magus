defmodule Magus.Usage.LimitEnforcerTest do
  use Magus.ResourceCase, async: true

  import Ecto.Query

  alias Magus.Usage
  alias Magus.Usage.PolicyEnforcer
  alias Magus.Usage.PolicyError
  alias Magus.Usage.Calculator
  alias Magus.Usage.PolicyErrorMessage

  require Ash.Query

  describe "request_cost_cents/3" do
    test "prices a token model from input + output tokens (FX-adjusted)" do
      # $1/M input, $5/M output; 20k in + 4k out = (20000 + 20000)/1e6 = $0.04
      # -> 4 CHF cents at the default 1:1 rate.
      model = %{
        output_cost_unit: :per_million_tokens,
        input_cost_value: Decimal.new("1"),
        output_cost_value: Decimal.new("5")
      }

      assert PolicyEnforcer.request_cost_cents(model, 20_000, 4_000) == 4
    end

    test "returns nil for non-token (image/video) models" do
      model = %{
        output_cost_unit: :per_image,
        input_cost_value: Decimal.new("0"),
        output_cost_value: Decimal.new("40")
      }

      assert PolicyEnforcer.request_cost_cents(model, 20_000, 4_000) == nil
    end
  end

  describe "request_cost_tier/1" do
    test "buckets CHF cents into cheap / moderate / expensive (nil passes through)" do
      assert PolicyEnforcer.request_cost_tier(nil) == nil
      assert PolicyEnforcer.request_cost_tier(0) == :cheap
      assert PolicyEnforcer.request_cost_tier(5) == :cheap
      assert PolicyEnforcer.request_cost_tier(6) == :moderate
      assert PolicyEnforcer.request_cost_tier(20) == :moderate
      assert PolicyEnforcer.request_cost_tier(21) == :expensive
    end
  end

  describe "PolicyError formatting (via core renderer)" do
    test "generates correct message for spend_cap with CHF formatting" do
      error = %PolicyError{
        limit_type: :spend_cap,
        current: 2000,
        limit: 2000,
        upgrade_path: "/settings/subscription"
      }

      message = PolicyErrorMessage.message(error)
      assert message =~ "CHF 20.00/CHF 20.00"
      assert message =~ "monthly spend cap"
    end

    test "generates correct message for storage_bytes with GB formatting" do
      error = %PolicyError{
        limit_type: :storage_bytes,
        current: 1_073_741_824,
        limit: 1_073_741_824,
        upgrade_path: "/settings/subscription"
      }

      message = PolicyErrorMessage.message(error)
      assert message =~ "1.0 GB"
    end

    test "generates correct message for max_upload_bytes" do
      error = %PolicyError{
        limit_type: :max_upload_bytes,
        current: 52_428_800,
        limit: 10_485_760,
        upgrade_path: "/settings/subscription"
      }

      message = PolicyErrorMessage.message(error)
      assert message =~ "10.0 MB"
    end

    test "generates correct message for storage_overage" do
      error = %PolicyError{
        limit_type: :storage_overage,
        current: 2_000_000_000,
        limit: 1_073_741_824,
        upgrade_path: "/settings/subscription"
      }

      message = PolicyErrorMessage.message(error)
      assert message =~ "over your storage limit"
    end

    test "generates correct message for mode_disabled" do
      error = %PolicyError{
        limit_type: :mode_disabled,
        upgrade_path: "/settings/subscription"
      }

      assert PolicyErrorMessage.message(error) =~ "not available on your current plan"
    end

    test "generates correct message for payment_required" do
      error = %PolicyError{
        limit_type: :payment_required,
        current: 1500,
        limit: 2000,
        upgrade_path: "/settings/subscription"
      }

      message = PolicyErrorMessage.message(error)
      assert message =~ "last payment failed"
      assert message =~ "pay-as-you-go"
    end
  end

  describe "check_mode_access/2" do
    setup do
      user = create_actor()
      free_plan = ensure_free_plan()

      {:ok, _subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user, free_plan: free_plan}
    end

    test "allows chat mode for any plan", %{user: user} do
      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :chat)
    end

    test "allows search mode for any plan", %{user: user} do
      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :search)
    end

    test "allows reasoning mode for any plan", %{user: user} do
      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :reasoning)
    end

    test "blocks image_generation when disabled on plan", %{user: user} do
      # Free plan has image_generation_enabled: false
      assert {:error, %PolicyError{limit_type: :mode_disabled}} =
               PolicyEnforcer.check_mode_access(user, :image_generation)
    end

    test "blocks video_generation when disabled on plan", %{user: user} do
      # Free plan has video_generation_enabled: false
      assert {:error, %PolicyError{limit_type: :mode_disabled}} =
               PolicyEnforcer.check_mode_access(user, :video_generation)
    end

    test "allows image_generation when enabled on plan", %{user: user} do
      # Create a plan with image generation enabled
      plan_with_image = generate(usage_plan(image_generation_enabled: true))

      {:ok, subscription} = Usage.get_user_subscription(user.id, authorize?: false)

      Usage.upgrade_subscription(
        subscription,
        %{usage_plan_id: plan_with_image.id},
        authorize?: false
      )

      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :image_generation)
    end

    test "allows video_generation when enabled on plan", %{user: user} do
      plan_with_video = generate(usage_plan(video_generation_enabled: true))

      {:ok, subscription} = Usage.get_user_subscription(user.id, authorize?: false)

      Usage.upgrade_subscription(
        subscription,
        %{usage_plan_id: plan_with_video.id},
        authorize?: false
      )

      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :video_generation)
    end

    test "exempt user bypasses mode restrictions", %{user: user} do
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

      # Free plan disables both, but exempt user bypasses
      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :image_generation)
      assert {:ok, :allowed} = PolicyEnforcer.check_mode_access(user, :video_generation)
    end
  end

  describe "check_usage/3 (money-based spend gate)" do
    setup do
      user = create_actor()
      free_plan = ensure_free_plan()

      {:ok, _subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      # Default cap is 2000 cents (CHF 20) unless the user sets their own.
      %{user: user, free_plan: free_plan, default_cap: Calculator.default_spend_cap_cents()}
    end

    test "allows models when under the spend cap with an empty wallet", %{user: user} do
      model = %{}
      assert {:ok, :allowed} = PolicyEnforcer.check_usage(user, model)
    end

    test "blocks when period usage reaches the cap and wallet is empty", %{
      user: user,
      default_cap: cap
    } do
      subscribe(user.id)
      set_sub_fields(user.id, period_usage_cents: cap)

      assert {:error, %PolicyError{limit_type: :spend_cap, current: ^cap, limit: ^cap}} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "no_spend_cap allows usage past the cap", %{user: user, default_cap: cap} do
      subscribe(user.id)

      set_sub_fields(user.id,
        period_usage_cents: cap,
        no_spend_cap: true
      )

      assert {:ok, :allowed} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "respects a user-set spend cap below the default", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, monthly_spend_cap_cents: 100, period_usage_cents: 100)

      assert {:error, %PolicyError{limit_type: :spend_cap, limit: 100}} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "free user is capped at the trial allowance, not the default cap", %{user: user} do
      trial_cap = Calculator.free_trial_spend_cap_cents()
      set_sub_fields(user.id, period_usage_cents: trial_cap)

      assert {:error, %PolicyError{limit_type: :trial_cap, limit: ^trial_cap}} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "free user's no_spend_cap is ignored (can't opt into unbillable postpaid)", %{
      user: user
    } do
      trial_cap = Calculator.free_trial_spend_cap_cents()

      set_sub_fields(user.id,
        period_usage_cents: trial_cap,
        no_spend_cap: true
      )

      assert {:error, %PolicyError{limit_type: :trial_cap}} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "model access is ungated: an expensive model is allowed on the free plan", %{
      user: user
    } do
      # Cost-based model gating was removed; spend caps are the only limit. A
      # model that the old free-plan cap (2x) would have blocked is no longer
      # rejected on model access. We hold the per-call spend estimate small so
      # the only thing under test is model access, not the spend cap.
      expensive_model = %{
        input_cost_value: Decimal.new("75"),
        output_cost_value: Decimal.new("150"),
        output_cost_unit: :per_million_tokens
      }

      assert {:ok, :allowed} =
               PolicyEnforcer.check_usage(user, expensive_model, estimated_cost_cents: 1)
    end

    test "allows exempt users regardless of spend", %{user: user, default_cap: cap} do
      set_sub_fields(user.id, period_usage_cents: cap * 100)

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

      # Even a model the free plan can't access passes for exempt users
      assert {:ok, :allowed} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "respects estimated_cost_cents option", %{user: user, default_cap: cap} do
      subscribe(user.id)
      # Leave only 5 cents of headroom under the cap.
      set_sub_fields(user.id, period_usage_cents: cap - 5)

      # A bare model estimates the 1-cent floor → still allowed.
      assert {:ok, :allowed} =
               PolicyEnforcer.check_usage(user, %{})

      # A larger explicit estimate exceeds the remaining headroom → blocked.
      assert {:error, %PolicyError{limit_type: :spend_cap}} =
               PolicyEnforcer.check_usage(user, %{}, estimated_cost_cents: 100)
    end
  end

  describe "check_file_upload/2" do
    setup do
      user = create_actor()
      free_plan = ensure_free_plan()

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user, free_plan: free_plan, subscription: subscription}
    end

    test "allows uploads within limits", %{user: user, free_plan: plan} do
      # Upload half the max size
      file_size = div(plan.max_upload_bytes, 2)

      assert {:ok, :allowed} = PolicyEnforcer.check_file_upload(user, file_size)
    end

    test "blocks files exceeding max_upload_bytes", %{user: user, free_plan: plan} do
      # File larger than max upload size
      file_size = plan.max_upload_bytes + 1

      assert {:error, %PolicyError{limit_type: :max_upload_bytes}} =
               PolicyEnforcer.check_file_upload(user, file_size)
    end

    test "blocks when storage would exceed quota", %{user: user, free_plan: plan} do
      # First, fill up most of the storage
      current_usage = plan.storage_bytes - 1000

      Usage.increment_storage_usage(user.id, current_usage, authorize?: false)

      # Try to upload a file that would exceed quota
      file_size = 5000

      assert {:error, %PolicyError{limit_type: :storage_bytes}} =
               PolicyEnforcer.check_file_upload(user, file_size)
    end

    test "blocks uploads when in overage state", %{user: user, free_plan: plan} do
      # Put user over their storage quota (simulating a downgrade)
      over_usage = plan.storage_bytes + 1_000_000

      Usage.increment_storage_usage(user.id, over_usage, authorize?: false)

      # Even a small file should be blocked
      assert {:error, %PolicyError{limit_type: :storage_overage}} =
               PolicyEnforcer.check_file_upload(user, 100)
    end

    test "allows exempt users to upload any size", %{user: user} do
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

      # Even a huge file should be allowed
      assert {:ok, :allowed} = PolicyEnforcer.check_file_upload(user, 10_000_000_000)
    end
  end

  describe "check_spend_budget/1 (model-less spend gate)" do
    setup do
      user = create_actor()
      free_plan = ensure_free_plan()

      {:ok, _subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user, default_cap: Calculator.default_spend_cap_cents()}
    end

    test "allows while under the cap", %{user: user} do
      assert {:ok, :allowed} = PolicyEnforcer.check_spend_budget(user)
    end

    test "blocks when the cap is reached and wallet is empty", %{user: user, default_cap: cap} do
      subscribe(user.id)
      set_sub_fields(user.id, period_usage_cents: cap)

      assert {:error, %PolicyError{limit_type: :spend_cap}} =
               PolicyEnforcer.check_spend_budget(user)
    end

    test "free user is blocked at the trial allowance with :trial_cap", %{user: user} do
      trial_cap = Calculator.free_trial_spend_cap_cents()
      set_sub_fields(user.id, period_usage_cents: trial_cap)

      assert {:error, %PolicyError{limit_type: :trial_cap}} =
               PolicyEnforcer.check_spend_budget(user)
    end

    test "past_due + no_spend_cap is blocked when wallet is empty", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :past_due, no_spend_cap: true)

      assert {:error, %PolicyError{limit_type: :payment_required}} =
               PolicyEnforcer.check_spend_budget(user)
    end

    test "active + no_spend_cap is still allowed (no regression)", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :active, no_spend_cap: true)

      assert {:ok, :allowed} = PolicyEnforcer.check_spend_budget(user)
    end

    test "past_due without no_spend_cap is also blocked when wallet empty", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :past_due)

      assert {:error, %PolicyError{limit_type: :payment_required}} =
               PolicyEnforcer.check_spend_budget(user)
    end
  end

  describe "check_usage/3 delinquent (past_due) gate" do
    setup do
      user = create_actor()
      free_plan = ensure_free_plan()

      {:ok, _subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user}
    end

    test "past_due + no_spend_cap with empty wallet returns :payment_required", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :past_due, no_spend_cap: true)

      assert {:error, %PolicyError{limit_type: :payment_required}} =
               PolicyEnforcer.check_usage(user, %{})
    end

    test "active + no_spend_cap stays allowed (no regression)", %{user: user} do
      subscribe(user.id)
      set_sub_fields(user.id, status: :active, no_spend_cap: true)

      assert {:ok, :allowed} =
               PolicyEnforcer.check_usage(user, %{})
    end
  end

  # Directly set pay-per-use fields on the personal subscription. No public
  # action accepts wallet/period/cap directly (they are maintained by
  # deduct_usage / Stripe in later PRs), so tests poke them via the repo.
  defp set_sub_fields(user_id, fields) do
    Usage.Account
    |> where([s], s.user_id == ^user_id and is_nil(s.sponsor_org_id))
    |> Magus.Repo.update_all(set: fields)
  end

  # Mark the personal subscription as Stripe-backed (billable): the user-set /
  # default spend caps only apply to subscribers; free users get the trial cap.
  defp subscribe(user_id) do
    set_sub_fields(user_id, stripe_subscription_id: "sub_test_#{user_id}")
  end
end
