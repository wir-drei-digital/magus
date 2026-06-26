defmodule Magus.Workspaces.ResendInviteTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces

  describe "resend_invite" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      unique_id = System.unique_integer([:positive])

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "Resend WS #{unique_id}", slug: "resend-ws-#{unique_id}"},
          actor: owner
        )

      %{owner: owner, workspace: workspace}
    end

    test "regenerates token and extends expiry for an invited member", %{
      owner: owner,
      workspace: workspace
    } do
      {:ok, original} =
        Workspaces.invite_member(workspace.id, "invitee@test.com", actor: owner)

      original_token = original.invite_token
      original_expiry = original.invite_expires_at

      # Small sleep to ensure the new expiry timestamp is strictly greater
      Process.sleep(10)

      {:ok, resent} = Workspaces.resend_invite(original, actor: owner)

      refute resent.invite_token == original_token
      assert DateTime.compare(resent.invite_expires_at, original_expiry) == :gt
    end

    test "fails on an already-accepted member", %{owner: owner, workspace: workspace} do
      invitee = generate(user())

      {:ok, invite} =
        Workspaces.invite_member(workspace.id, to_string(invitee.email), actor: owner)

      {:ok, active_member} = Workspaces.accept_invite(invite.invite_token, actor: invitee)

      assert {:error, _} = Workspaces.resend_invite(active_member, actor: owner)
    end

    test "fails on a deactivated member", %{owner: owner, workspace: workspace} do
      invitee = generate(user())

      {:ok, invite} =
        Workspaces.invite_member(workspace.id, to_string(invitee.email), actor: owner)

      {:ok, active_member} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
      {:ok, deactivated} = Workspaces.deactivate_member(active_member, actor: owner)

      assert {:error, _} = Workspaces.resend_invite(deactivated, actor: owner)
    end

    test "non-owner cannot resend an invite", %{owner: owner, workspace: workspace} do
      non_owner = generate(user())

      {:ok, invite} =
        Workspaces.invite_member(workspace.id, "invitee2@test.com", actor: owner)

      assert {:error, _} = Workspaces.resend_invite(invite, actor: non_owner)
    end
  end
end
