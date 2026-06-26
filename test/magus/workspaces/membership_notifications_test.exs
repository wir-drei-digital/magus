defmodule Magus.Workspaces.MembershipNotificationsTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Workspaces

  # Unique slug helper to avoid identity conflicts across tests.
  defp unique_slug, do: "ws-#{System.unique_integer([:positive])}"

  describe "invite notification" do
    test "invite is a no-op for unregistered invitees (user_id is nil at invite time)" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test", slug: unique_slug()}, actor: owner)

      invitee = generate(user())

      {:ok, _invite} = Workspaces.invite_member(workspace.id, invitee.email, actor: owner)

      # invite action does not resolve user_id, so no in-app notification is fired.
      notifications =
        Magus.Notifications.Notification
        |> Ash.Query.filter(user_id == ^invitee.id and notification_type == :workspace_invite)
        |> Ash.read!(authorize?: false)

      assert Enum.empty?(notifications)
    end
  end

  describe "change_role notification" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test", slug: unique_slug()}, actor: owner)

      member_user = generate(user())

      {:ok, invite} = Workspaces.invite_member(workspace.id, member_user.email, actor: owner)
      {:ok, member} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      %{owner: owner, member: member, member_user: member_user}
    end

    test "change_role emits workspace_role_changed notification to target user", %{
      owner: owner,
      member: member,
      member_user: member_user
    } do
      {:ok, _} = Workspaces.change_member_role(member, :admin, actor: owner)

      notifications =
        Magus.Notifications.Notification
        |> Ash.Query.filter(
          user_id == ^member_user.id and notification_type == :workspace_role_changed
        )
        |> Ash.read!(authorize?: false)

      assert length(notifications) == 1
    end
  end

  describe "deactivate notification" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test", slug: unique_slug()}, actor: owner)

      member_user = generate(user())

      {:ok, invite} = Workspaces.invite_member(workspace.id, member_user.email, actor: owner)
      {:ok, member} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      %{owner: owner, member: member, member_user: member_user}
    end

    test "deactivate emits workspace_removed notification to removed user", %{
      owner: owner,
      member: member,
      member_user: member_user
    } do
      {:ok, _} = Workspaces.deactivate_member(member, actor: owner)

      notifications =
        Magus.Notifications.Notification
        |> Ash.Query.filter(
          user_id == ^member_user.id and notification_type == :workspace_removed
        )
        |> Ash.read!(authorize?: false)

      assert length(notifications) == 1
    end
  end

  describe "transfer_ownership notification" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test", slug: unique_slug()}, actor: owner)

      member_user = generate(user())

      {:ok, invite} = Workspaces.invite_member(workspace.id, member_user.email, actor: owner)
      {:ok, member} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      %{owner: owner, member: member, member_user: member_user}
    end

    test "transfer_ownership emits workspace_ownership_transferred notification to new owner", %{
      owner: owner,
      member: member,
      member_user: member_user
    } do
      {:ok, _} = Workspaces.transfer_ownership_to(member, actor: owner)

      notifications =
        Magus.Notifications.Notification
        |> Ash.Query.filter(
          user_id == ^member_user.id and
            notification_type == :workspace_ownership_transferred
        )
        |> Ash.read!(authorize?: false)

      assert length(notifications) == 1
    end
  end
end
