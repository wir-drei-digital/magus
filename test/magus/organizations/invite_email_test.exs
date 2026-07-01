defmodule Magus.Organizations.InviteEmailTest do
  @moduledoc """
  Verifies that inviting (and re-inviting) an org member delivers an invite
  email carrying the `/organizations/invite/:token` accept link.
  """
  use Magus.DataCase, async: true

  import Swoosh.TestAssertions
  import Magus.Generators

  alias Magus.Organizations

  # Drain any emails delivered during org/workspace bootstrap so the invite
  # assertions below match on THE ORG INVITE email specifically.
  defp drain_mailbox do
    receive do
      {:email, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  setup do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(%{name: "Mail Org", slug: "mail-org"}, actor: owner)

    drain_mailbox()

    %{owner: owner, org: org}
  end

  test "inviting a member sends an invite email with the org accept link", %{
    owner: owner,
    org: org
  } do
    {:ok, member} =
      Organizations.invite_org_member(org.id, "invitee@test.com", actor: owner)

    assert_email_sent(fn email ->
      assert [{"", "invitee@test.com"}] = email.to
      assert email.text_body =~ "/organizations/invite/#{member.invite_token}"
      assert email.html_body =~ "/organizations/invite/#{member.invite_token}"
    end)
  end

  test "resending an invite sends a fresh invite email with the new token", %{
    owner: owner,
    org: org
  } do
    {:ok, member} =
      Organizations.invite_org_member(org.id, "invitee@test.com", actor: owner)

    drain_mailbox()

    {:ok, resent} = Organizations.resend_org_invite(member, actor: owner)

    refute resent.invite_token == member.invite_token

    assert_email_sent(fn email ->
      assert [{"", "invitee@test.com"}] = email.to
      assert email.text_body =~ "/organizations/invite/#{resent.invite_token}"
    end)
  end
end
