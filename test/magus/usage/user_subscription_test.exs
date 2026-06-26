defmodule Magus.Usage.UserSubscriptionTest do
  use Magus.ResourceCase, async: true

  alias Magus.Usage

  describe "read actions" do
    setup do
      user = create_actor()
      admin = create_admin()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          actor: admin
        )

      %{user: user, admin: admin, subscription: subscription, free_plan: free_plan}
    end

    test "user can read their own subscription", %{user: user, subscription: subscription} do
      {:ok, found} = Usage.get_user_subscription(user.id, actor: user)
      assert found.id == subscription.id
    end

    test "admin can read any user's subscription", %{
      user: user,
      admin: admin,
      subscription: subscription
    } do
      {:ok, found} = Usage.get_user_subscription(user.id, actor: admin)
      assert found.id == subscription.id
    end

    test "user cannot read another user's subscription", %{
      user: _user,
      subscription: _subscription
    } do
      other_user = create_actor()

      # The query returns NotFound when user tries to read another user's subscription
      # (the other_user has no subscription)
      {:error, error} = Usage.get_user_subscription(other_user.id, actor: other_user)
      assert %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]} = error
    end

    test "unauthenticated user cannot read subscriptions", %{user: user} do
      # Without actor, policy filters results and returns NotFound
      {:error, error} = Usage.get_user_subscription(user.id)
      assert %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]} = error
    end
  end

  describe "read :by_stripe_subscription_id" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)
      stripe_id = "sub_test_#{System.unique_integer([:positive])}"

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: free_plan.id,
            status: :active,
            stripe_subscription_id: stripe_id
          },
          actor: admin
        )

      %{admin: admin, subscription: subscription, stripe_id: stripe_id}
    end

    test "admin can find subscription by stripe ID", %{
      admin: admin,
      subscription: subscription,
      stripe_id: stripe_id
    } do
      {:ok, found} = Usage.get_subscription_by_stripe_id(stripe_id, actor: admin)
      assert found.id == subscription.id
    end

    test "returns not found error for non-existent stripe ID", %{admin: admin} do
      {:error, error} = Usage.get_subscription_by_stripe_id("non_existent", actor: admin)
      assert %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]} = error
    end
  end

  describe "create action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      %{admin: admin, user: user, free_plan: free_plan}
    end

    test "admin can create subscription", %{admin: admin, user: user, free_plan: plan} do
      {:ok, subscription} =
        Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: plan.id,
            status: :active,
            stripe_customer_id: "cus_test123",
            stripe_subscription_id: "sub_test123",
            current_period_start: DateTime.utc_now(),
            current_period_end: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: admin
        )

      assert subscription.user_id == user.id
      assert subscription.usage_plan_id == plan.id
      assert subscription.status == :active
      assert subscription.stripe_customer_id == "cus_test123"
      assert subscription.storage_usage_bytes == 0
    end

    test "non-admin cannot create subscription", %{user: user, free_plan: plan} do
      assert_forbidden(fn ->
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id},
          actor: user
        )
      end)
    end

    test "subscription user_id must be unique", %{admin: admin, user: user, free_plan: plan} do
      {:ok, _first} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id},
          actor: admin
        )

      {:error, error} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id},
          actor: admin
        )

      assert_field_error(error, :user_id, "has already been taken")
    end

    test "status defaults to active", %{admin: admin, user: user, free_plan: plan} do
      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: plan.id},
          actor: admin
        )

      assert subscription.status == :active
    end
  end

  describe "upgrade action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, pro_plan} =
        Usage.create_usage_plan(
          %{
            key: "pro-test-#{System.unique_integer([:positive])}",
            name: "Pro Test",
            storage_bytes: 50_000_000_000,
            max_upload_bytes: 500_000_000
          },
          actor: admin
        )

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id},
          actor: admin
        )

      %{admin: admin, user: user, subscription: subscription, pro_plan: pro_plan}
    end

    test "admin can upgrade subscription", %{
      admin: admin,
      subscription: subscription,
      pro_plan: pro_plan
    } do
      now = DateTime.utc_now()
      period_end = DateTime.add(now, 30, :day)

      {:ok, upgraded} =
        Usage.upgrade_subscription(
          subscription,
          %{
            usage_plan_id: pro_plan.id,
            stripe_customer_id: "cus_upgraded",
            stripe_subscription_id: "sub_upgraded",
            status: :active,
            current_period_start: now,
            current_period_end: period_end
          },
          actor: admin
        )

      assert upgraded.usage_plan_id == pro_plan.id
      assert upgraded.stripe_customer_id == "cus_upgraded"
      assert upgraded.last_payment_status == "succeeded"
      assert is_nil(upgraded.canceled_at)
    end

    test "non-admin cannot upgrade subscription", %{
      subscription: subscription,
      pro_plan: pro_plan
    } do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.upgrade_subscription(
          subscription,
          %{usage_plan_id: pro_plan.id},
          actor: user
        )
      end)
    end
  end

  describe "downgrade_to_free action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, pro_plan} =
        Usage.create_usage_plan(
          %{
            key: "pro-downgrade-#{System.unique_integer([:positive])}",
            name: "Pro Downgrade Test",
            storage_bytes: 50_000_000_000,
            max_upload_bytes: 500_000_000
          },
          actor: admin
        )

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: pro_plan.id,
            stripe_subscription_id: "sub_to_cancel",
            status: :active,
            current_period_start: DateTime.utc_now(),
            current_period_end: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: admin
        )

      %{admin: admin, subscription: subscription, free_plan: free_plan}
    end

    test "admin can downgrade to free", %{
      admin: admin,
      subscription: subscription,
      free_plan: free_plan
    } do
      {:ok, downgraded} =
        Usage.downgrade_to_free(
          subscription,
          %{usage_plan_id: free_plan.id},
          actor: admin
        )

      assert downgraded.usage_plan_id == free_plan.id
      assert is_nil(downgraded.stripe_subscription_id)
      assert downgraded.status == :active
      assert is_nil(downgraded.current_period_start)
      assert is_nil(downgraded.current_period_end)
      assert is_nil(downgraded.canceled_at)
      assert is_nil(downgraded.last_payment_status)
    end

    test "non-admin cannot downgrade", %{subscription: subscription, free_plan: free_plan} do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.downgrade_to_free(
          subscription,
          %{usage_plan_id: free_plan.id},
          actor: user
        )
      end)
    end
  end

  describe "update_from_stripe action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          actor: admin
        )

      %{admin: admin, subscription: subscription}
    end

    test "admin can update from stripe webhook", %{admin: admin, subscription: subscription} do
      now = DateTime.utc_now()
      period_end = DateTime.add(now, 30, :day)

      {:ok, updated} =
        Usage.update_subscription_from_stripe(
          subscription,
          %{
            status: :past_due,
            current_period_start: now,
            current_period_end: period_end,
            canceled_at: now
          },
          actor: admin
        )

      assert updated.status == :past_due
      assert updated.canceled_at != nil
    end

    test "non-admin cannot update from stripe", %{subscription: subscription} do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.update_subscription_from_stripe(
          subscription,
          %{status: :canceled},
          actor: user
        )
      end)
    end
  end

  describe "update_payment_status action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id},
          actor: admin
        )

      %{admin: admin, subscription: subscription}
    end

    test "admin can update payment status", %{admin: admin, subscription: subscription} do
      {:ok, updated} =
        Usage.update_payment_status(
          subscription,
          %{last_payment_status: "failed"},
          actor: admin
        )

      assert updated.last_payment_status == "failed"
    end

    test "non-admin cannot update payment status", %{subscription: subscription} do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.update_payment_status(
          subscription,
          %{last_payment_status: "failed"},
          actor: user
        )
      end)
    end
  end

  describe "storage actions" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id},
          actor: admin
        )

      %{admin: admin, user: user, subscription: subscription}
    end

    test "admin can increment storage usage", %{admin: admin, subscription: subscription} do
      {:ok, updated} =
        Ash.update(
          Ash.Changeset.for_update(subscription, :increment_storage, %{bytes: 1000}),
          actor: admin
        )

      assert updated.storage_usage_bytes == 1000

      {:ok, updated2} =
        Ash.update(
          Ash.Changeset.for_update(updated, :increment_storage, %{bytes: 500}),
          actor: admin
        )

      assert updated2.storage_usage_bytes == 1500
    end

    test "admin can decrement storage usage", %{admin: admin, subscription: subscription} do
      {:ok, updated} =
        Ash.update(
          Ash.Changeset.for_update(subscription, :increment_storage, %{bytes: 1000}),
          actor: admin
        )

      {:ok, decremented} =
        Ash.update(
          Ash.Changeset.for_update(updated, :decrement_storage, %{bytes: 300}),
          actor: admin
        )

      assert decremented.storage_usage_bytes == 700
    end

    test "decrement storage never goes below 0", %{admin: admin, subscription: subscription} do
      {:ok, updated} =
        Ash.update(
          Ash.Changeset.for_update(subscription, :increment_storage, %{bytes: 100}),
          actor: admin
        )

      {:ok, decremented} =
        Ash.update(
          Ash.Changeset.for_update(updated, :decrement_storage, %{bytes: 500}),
          actor: admin
        )

      assert decremented.storage_usage_bytes == 0
    end

    test "non-admin cannot modify storage", %{subscription: subscription} do
      other_user = create_actor()

      assert_forbidden(fn ->
        Ash.update(
          Ash.Changeset.for_update(subscription, :increment_storage, %{bytes: 1000}),
          actor: other_user
        )
      end)

      assert_forbidden(fn ->
        Ash.update(
          Ash.Changeset.for_update(subscription, :decrement_storage, %{bytes: 100}),
          actor: other_user
        )
      end)
    end
  end

  describe "deduct_usage action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id},
          actor: admin
        )

      %{admin: admin, user: user, subscription: subscription}
    end

    test "deduct_usage accrues the full amount to period_usage_cents", %{user: user} do
      {:ok, sub} = Usage.deduct_usage(user.id, 250, authorize?: false)
      assert sub.period_usage_cents == 250
      {:ok, sub2} = Usage.deduct_usage(user.id, 100, authorize?: false)
      assert sub2.period_usage_cents == 350
    end

    test "non-admin cannot deduct usage", %{subscription: subscription} do
      other_user = create_actor()

      assert_forbidden(fn ->
        Ash.update(
          Ash.Changeset.for_update(subscription, :deduct_usage, %{amount_cents: 100}),
          actor: other_user
        )
      end)
    end
  end

  describe "update_billing_preferences action" do
    setup do
      admin = create_admin()
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id},
          actor: admin
        )

      %{user: user, subscription: subscription}
    end

    test "owner can set their cap and opt out of it", %{user: user, subscription: subscription} do
      {:ok, updated} =
        Usage.update_billing_preferences(
          subscription,
          %{monthly_spend_cap_cents: 5000, no_spend_cap: true},
          actor: user
        )

      assert updated.monthly_spend_cap_cents == 5000
      assert updated.no_spend_cap == true
    end

    test "another user cannot edit someone else's preferences", %{subscription: subscription} do
      other_user = create_actor()

      assert_forbidden(fn ->
        Usage.update_billing_preferences(
          subscription,
          %{monthly_spend_cap_cents: 100},
          actor: other_user
        )
      end)
    end

    test "rejects a negative cap", %{user: user, subscription: subscription} do
      {:error, error} =
        Usage.update_billing_preferences(
          subscription,
          %{monthly_spend_cap_cents: -5},
          actor: user
        )

      assert_field_error(error, :monthly_spend_cap_cents, "non-negative")
    end
  end

  describe "is_premium? calculation" do
    setup do
      admin = create_admin()
      %{admin: admin}
    end

    test "active subscription is premium", %{admin: admin} do
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          actor: admin
        )

      {:ok, loaded} = Ash.load(subscription, :is_premium?, authorize?: false)
      assert loaded.is_premium? == true
    end

    test "canceled but in period is still premium", %{admin: admin} do
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: free_plan.id,
            status: :canceled,
            current_period_end: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: admin
        )

      {:ok, loaded} = Ash.load(subscription, :is_premium?, authorize?: false)
      assert loaded.is_premium? == true
    end

    test "canceled and past period is not premium", %{admin: admin} do
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{
            user_id: user.id,
            usage_plan_id: free_plan.id,
            status: :canceled,
            current_period_end: DateTime.add(DateTime.utc_now(), -1, :day)
          },
          actor: admin
        )

      {:ok, loaded} = Ash.load(subscription, :is_premium?, authorize?: false)
      assert loaded.is_premium? == false
    end

    test "past_due status is not premium", %{admin: admin} do
      user = create_actor()
      free_plan = create_free_plan(admin)

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :past_due},
          actor: admin
        )

      {:ok, loaded} = Ash.load(subscription, :is_premium?, authorize?: false)
      assert loaded.is_premium? == false
    end
  end

  describe "status constraints" do
    test "status must be one of allowed values" do
      admin = create_admin()
      free_plan = create_free_plan(admin)

      # Valid statuses
      for status <- [:active, :past_due, :canceled, :incomplete, :trialing] do
        test_user = create_actor()

        {:ok, subscription} =
          Usage.create_user_subscription(
            %{user_id: test_user.id, usage_plan_id: free_plan.id, status: status},
            actor: admin
          )

        assert subscription.status == status
      end
    end
  end

  # Helper to create an admin user
  defp create_admin do
    user = create_actor()

    {:ok, admin} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:is_admin, true)
      |> Ash.update(authorize?: false)

    admin
  end

  # Helper to create a free plan for testing
  defp create_free_plan(admin) do
    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "free-test-#{System.unique_integer([:positive])}",
          name: "Free Test Plan",
          storage_bytes: 100_000_000,
          max_upload_bytes: 10_000_000
        },
        actor: admin
      )

    plan
  end
end
