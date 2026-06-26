defmodule Magus.Usage.UsagePlanTest do
  use Magus.ResourceCase, async: true

  alias Magus.Usage

  describe "read actions" do
    test "anyone can read plans without actor" do
      {:ok, plans} = Usage.list_active_plans()
      assert is_list(plans)
    end

    test "anyone can read plans with actor" do
      user = create_actor()

      {:ok, plans} = Usage.list_active_plans(actor: user)
      assert is_list(plans)
    end

    test "get_free_plan returns the free plan" do
      admin = create_admin()

      # Create a plan with key "free"
      {:ok, _created} =
        Usage.create_usage_plan(
          %{key: "free", name: "Free Plan", storage_bytes: 0, max_upload_bytes: 0},
          actor: admin
        )

      {:ok, plan} = Usage.get_free_plan()
      assert plan.key == "free"
    end

    test "list_active_plans returns only active plans" do
      admin = create_admin()

      # Create an inactive plan
      {:ok, _inactive} =
        Usage.create_usage_plan(
          %{
            key: "test-inactive-#{System.unique_integer([:positive])}",
            name: "Inactive Plan",
            is_active: false,
            storage_bytes: 0,
            max_upload_bytes: 0
          },
          actor: admin
        )

      {:ok, plans} = Usage.list_active_plans()
      refute Enum.any?(plans, &(&1.is_active == false))
    end

    test "list_active_plans returns plans sorted by sort_order" do
      {:ok, plans} = Usage.list_active_plans()

      sort_orders = Enum.map(plans, & &1.sort_order)
      assert sort_orders == Enum.sort(sort_orders)
    end
  end

  describe "create action" do
    test "admin can create a plan" do
      admin = create_admin()
      unique_key = "test-plan-#{System.unique_integer([:positive])}"

      {:ok, plan} =
        Usage.create_usage_plan(
          %{
            key: unique_key,
            name: "Test Plan",
            description: "A test plan",
            price_monthly_cents: 999,
            storage_bytes: 10_000_000_000,
            max_upload_bytes: 100_000_000,
            is_active: true,
            sort_order: 99
          },
          actor: admin
        )

      assert plan.key == unique_key
      assert plan.name == "Test Plan"
      assert plan.description == "A test plan"
      assert plan.price_monthly_cents == 999
      assert plan.storage_bytes == 10_000_000_000
      assert plan.max_upload_bytes == 100_000_000
      assert plan.is_active == true
      assert plan.sort_order == 99
    end

    test "non-admin cannot create a plan" do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.create_usage_plan(
          %{
            key: "test-plan-#{System.unique_integer([:positive])}",
            name: "Test Plan",
            storage_bytes: 0,
            max_upload_bytes: 0
          },
          actor: user
        )
      end)
    end

    test "unauthenticated user cannot create a plan" do
      assert_forbidden(fn ->
        Usage.create_usage_plan(%{
          key: "test-plan-#{System.unique_integer([:positive])}",
          name: "Test Plan",
          storage_bytes: 0,
          max_upload_bytes: 0
        })
      end)
    end

    test "plan key must be unique" do
      admin = create_admin()
      key = "unique-key-#{System.unique_integer([:positive])}"

      {:ok, _plan} =
        Usage.create_usage_plan(
          %{key: key, name: "First Plan", storage_bytes: 0, max_upload_bytes: 0},
          actor: admin
        )

      {:error, error} =
        Usage.create_usage_plan(
          %{key: key, name: "Second Plan", storage_bytes: 0, max_upload_bytes: 0},
          actor: admin
        )

      assert_field_error(error, :key, "has already been taken")
    end
  end

  describe "update action" do
    setup do
      admin = create_admin()

      {:ok, plan} =
        Usage.create_usage_plan(
          %{
            key: "test-plan-#{System.unique_integer([:positive])}",
            name: "Original Name",
            storage_bytes: 1000,
            max_upload_bytes: 100
          },
          actor: admin
        )

      %{admin: admin, plan: plan}
    end

    test "admin can update a plan", %{admin: admin, plan: plan} do
      {:ok, updated} =
        Usage.update_usage_plan(
          plan,
          %{
            name: "Updated Name",
            description: "Updated description",
            is_active: false
          },
          actor: admin
        )

      assert updated.name == "Updated Name"
      assert updated.description == "Updated description"
      assert updated.is_active == false
      # Key should remain unchanged since it's not in accept list for update
      assert updated.key == plan.key
    end

    test "non-admin cannot update a plan", %{plan: plan} do
      user = create_actor()

      assert_forbidden(fn ->
        Usage.update_usage_plan(plan, %{name: "Hacked"}, actor: user)
      end)
    end

    test "unauthenticated user cannot update a plan", %{plan: plan} do
      assert_forbidden(fn ->
        Usage.update_usage_plan(plan, %{name: "Hacked"})
      end)
    end
  end

  describe "attributes and defaults" do
    test "plan has proper defaults" do
      admin = create_admin()

      {:ok, plan} =
        Usage.create_usage_plan(
          %{
            key: "defaults-test-#{System.unique_integer([:positive])}",
            name: "Defaults Test"
          },
          actor: admin
        )

      assert plan.price_monthly_cents == 0
      assert plan.storage_bytes == 0
      assert plan.max_upload_bytes == 0
      assert plan.is_active == true
      assert plan.sort_order == 0
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
end
