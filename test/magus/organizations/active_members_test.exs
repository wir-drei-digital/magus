defmodule Magus.Organizations.ActiveMembersTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  describe "list_active_org_members/2" do
    test "returns only active members that have a user_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, org} =
        Organizations.create_organization(
          %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      # Pending invite: status :invited with a nil user_id — must be excluded.
      {:ok, _invite} =
        Organizations.invite_org_member(org.id, "invitee@test.com", actor: owner)

      assert {:ok, members} =
               Organizations.list_active_org_members(org.id, authorize?: false)

      assert [member] = members
      assert member.user_id == owner.id
      assert member.status == :active
    end
  end

  describe "downgrade_to_free_plan/2" do
    test "downgrading an upgraded account clears its stripe_subscription_id" do
      _free = ensure_free_plan()

      # A free plan present means registration auto-provisions a free
      # subscription for the new user; fetch and upgrade that one.
      user = generate(user())

      {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

      {:ok, upgraded} =
        Magus.Usage.upgrade_subscription(
          sub,
          %{stripe_subscription_id: "sub_downgrade_test", status: :active},
          authorize?: false
        )

      assert upgraded.stripe_subscription_id == "sub_downgrade_test"

      assert {:ok, downgraded} =
               Magus.Usage.downgrade_to_free_plan(upgraded, authorize?: false)

      assert is_nil(downgraded.stripe_subscription_id)
    end

    test "returns {:error, :no_free_plan} when no free plan is configured" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

      assert {:error, :no_free_plan} =
               Magus.Usage.downgrade_to_free_plan(sub, authorize?: false)
    end
  end
end
