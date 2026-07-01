defmodule Magus.Organizations.OrganizationMemberTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  defp make_org(owner) do
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Org", slug: "org-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    org
  end

  describe "invite" do
    test "owner invites a member by email" do
      owner = generate(user())
      org = make_org(owner)

      {:ok, invite} =
        Organizations.invite_org_member(org.id, "new@test.com", actor: owner)

      assert invite.organization_id == org.id
      assert invite.invite_email == "new@test.com"
      assert invite.role == :member
      assert invite.status == :invited
      assert invite.user_id == nil
      assert invite.invite_token != nil
      assert invite.invited_at != nil
      assert invite.joined_at == nil
    end
  end

  describe "accept" do
    test "accepting an invite activates membership" do
      owner = generate(user())
      org = make_org(owner)
      {:ok, invite} = Organizations.invite_org_member(org.id, "invitee@test.com", actor: owner)

      accepting = generate(user())
      {:ok, member} = Organizations.accept_invite(invite.invite_token, actor: accepting)

      assert member.status == :active
      assert member.user_id == accepting.id
      assert member.joined_at != nil
    end

    test "invalid token returns error" do
      accepting = generate(user())
      assert {:error, _} = Organizations.accept_invite("bogus", actor: accepting)
    end
  end
end
