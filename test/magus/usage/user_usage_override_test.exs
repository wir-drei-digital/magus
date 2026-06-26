defmodule Magus.Usage.UserUsageOverrideTest do
  use Magus.ResourceCase, async: true

  alias Magus.Usage

  require Ash.Query

  describe "read action" do
    setup do
      admin = create_admin()
      user = create_actor()

      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Test override",
            bonus_storage_bytes: 100
          },
          actor: admin
        )

      %{admin: admin, user: user, override: override}
    end

    test "admin can read overrides", %{admin: admin, override: override} do
      {:ok, [found]} =
        Usage.Override
        |> Ash.Query.filter(id == ^override.id)
        |> Ash.read(actor: admin)

      assert found.id == override.id
    end

    test "non-admin cannot read overrides", %{user: user, override: override} do
      {:ok, results} =
        Usage.Override
        |> Ash.Query.filter(id == ^override.id)
        |> Ash.read(actor: user)

      assert results == []
    end

    test "unauthenticated user cannot read overrides", %{override: override} do
      {:ok, results} =
        Usage.Override
        |> Ash.Query.filter(id == ^override.id)
        |> Ash.read()

      assert results == []
    end
  end

  describe "read :active_for_user" do
    setup do
      admin = create_admin()
      user = create_actor()
      %{admin: admin, user: user}
    end

    test "returns only active (non-expired) overrides", %{admin: admin, user: user} do
      # Create an active override (no expiration)
      {:ok, active} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Active override",
            bonus_storage_bytes: 50
          },
          actor: admin
        )

      # Create an active override (future expiration)
      {:ok, future} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :promotional,
            reason: "Future expiration",
            bonus_storage_bytes: 25,
            expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: admin
        )

      # Create an expired override
      {:ok, _expired} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Expired override",
            bonus_storage_bytes: 1000,
            expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
          },
          actor: admin
        )

      {:ok, results} = Usage.list_active_overrides_for_user(user.id, actor: admin)

      result_ids = Enum.map(results, & &1.id)
      assert active.id in result_ids
      assert future.id in result_ids
      assert length(results) == 2
    end

    test "returns empty list for user with no overrides", %{admin: admin} do
      other_user = create_actor()
      {:ok, results} = Usage.list_active_overrides_for_user(other_user.id, actor: admin)
      assert results == []
    end

    test "non-admin cannot query active overrides", %{user: user} do
      {:ok, results} = Usage.list_active_overrides_for_user(user.id, actor: user)
      assert results == []
    end
  end

  describe "create action" do
    setup do
      admin = create_admin()
      user = create_actor()
      %{admin: admin, user: user}
    end

    test "admin can create bonus override", %{admin: admin, user: user} do
      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Beta tester reward",
            bonus_storage_bytes: 10_000_000_000
          },
          actor: admin
        )

      assert override.user_id == user.id
      assert override.override_type == :bonus
      assert override.reason == "Beta tester reward"
      assert override.bonus_storage_bytes == 10_000_000_000
      assert override.exempt_from_limits == false
    end

    test "admin can create exemption override", %{admin: admin, user: user} do
      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :exemption,
            reason: "Team member",
            exempt_from_limits: true
          },
          actor: admin
        )

      assert override.override_type == :exemption
      assert override.exempt_from_limits == true
    end

    test "admin can create promotional override with expiration", %{admin: admin, user: user} do
      expires = DateTime.add(DateTime.utc_now(), 7, :day)

      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :promotional,
            reason: "Holiday promotion",
            bonus_storage_bytes: 200,
            expires_at: expires
          },
          actor: admin
        )

      assert override.override_type == :promotional
      assert DateTime.compare(override.expires_at, expires) == :eq
    end

    test "non-admin cannot create override", %{user: user} do
      assert_forbidden(fn ->
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Self-granted bonus"
          },
          actor: user
        )
      end)
    end

    test "unauthenticated user cannot create override", %{user: user} do
      assert_forbidden(fn ->
        Usage.create_usage_override(%{
          user_id: user.id,
          override_type: :bonus,
          reason: "Anonymous bonus"
        })
      end)
    end

    test "override_type must be valid", %{admin: admin, user: user} do
      {:error, error} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :invalid_type,
            reason: "Invalid"
          },
          actor: admin
        )

      assert_field_error(error, :override_type, "must be one of")
    end

    test "defaults are set correctly", %{admin: admin, user: user} do
      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Defaults test"
          },
          actor: admin
        )

      assert override.bonus_storage_bytes == 0
      assert override.bonus_storage_bytes == 0
      assert override.exempt_from_limits == false
      assert is_nil(override.expires_at)
    end
  end

  describe "update action" do
    setup do
      admin = create_admin()
      user = create_actor()

      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "Original reason",
            bonus_storage_bytes: 50
          },
          actor: admin
        )

      %{admin: admin, user: user, override: override}
    end

    test "admin can update override", %{admin: admin, override: override} do
      {:ok, updated} =
        Usage.update_usage_override(
          override,
          %{
            reason: "Updated reason",
            bonus_storage_bytes: 100
          },
          actor: admin
        )

      assert updated.reason == "Updated reason"
      assert updated.bonus_storage_bytes == 100
    end

    test "admin can change override type", %{admin: admin, override: override} do
      {:ok, updated} =
        Usage.update_usage_override(
          override,
          %{override_type: :exemption, exempt_from_limits: true},
          actor: admin
        )

      assert updated.override_type == :exemption
      assert updated.exempt_from_limits == true
    end

    test "admin can set expiration", %{admin: admin, override: override} do
      expires = DateTime.add(DateTime.utc_now(), 30, :day)

      {:ok, updated} =
        Usage.update_usage_override(
          override,
          %{expires_at: expires},
          actor: admin
        )

      assert DateTime.compare(updated.expires_at, expires) == :eq
    end

    test "non-admin cannot update override", %{user: user, override: override} do
      assert_forbidden(fn ->
        Usage.update_usage_override(
          override,
          %{reason: "Hacked"},
          actor: user
        )
      end)
    end

    test "unauthenticated user cannot update override", %{override: override} do
      assert_forbidden(fn ->
        Usage.update_usage_override(override, %{reason: "Hacked"})
      end)
    end
  end

  describe "destroy action" do
    setup do
      admin = create_admin()
      user = create_actor()

      {:ok, override} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "To be deleted"
          },
          actor: admin
        )

      %{admin: admin, user: user, override: override}
    end

    test "admin can delete override", %{admin: admin, override: override} do
      assert :ok = Usage.delete_usage_override(override, actor: admin)

      {:ok, results} =
        Usage.Override
        |> Ash.Query.filter(id == ^override.id)
        |> Ash.read(actor: admin)

      assert results == []
    end

    test "non-admin cannot delete override", %{user: user, override: override} do
      assert_forbidden(fn ->
        Usage.delete_usage_override(override, actor: user)
      end)
    end

    test "unauthenticated user cannot delete override", %{override: override} do
      assert_forbidden(fn ->
        Usage.delete_usage_override(override)
      end)
    end
  end

  describe "multiple overrides for same user" do
    test "user can have multiple active overrides" do
      admin = create_admin()
      user = create_actor()

      {:ok, override1} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :bonus,
            reason: "First bonus",
            bonus_storage_bytes: 50
          },
          actor: admin
        )

      {:ok, override2} =
        Usage.create_usage_override(
          %{
            user_id: user.id,
            override_type: :promotional,
            reason: "Promo bonus",
            bonus_storage_bytes: 100
          },
          actor: admin
        )

      {:ok, results} = Usage.list_active_overrides_for_user(user.id, actor: admin)

      assert length(results) == 2
      result_ids = Enum.map(results, & &1.id)
      assert override1.id in result_ids
      assert override2.id in result_ids
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
