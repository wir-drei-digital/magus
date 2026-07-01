defmodule MagusWeb.Organizations.AcceptInviteTest do
  @moduledoc """
  Tests for the org invite-accept LiveView at `/organizations/invite/:token`.

  - A logged-in invitee accepting is redirected to the app root and their
    membership flips to `:active`.
  - An anonymous invitee sees sign-in/register links carrying the
    `org_invite_token`, so the post-auth round-trip lands back here.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  alias Magus.Organizations

  test "a logged-in invitee accepts and is redirected to the app root", %{conn: conn} do
    owner = generate(user())
    ensure_workspace_plan(owner)
    invitee = generate(user())
    ensure_workspace_plan(invitee)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, member} =
      Organizations.invite_org_member(org.id, to_string(invitee.email), actor: owner)

    conn = log_in_user(conn, invitee)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn, "/organizations/invite/#{member.invite_token}")

    {:ok, reloaded} =
      Organizations.OrganizationMember |> Ash.get(member.id, authorize?: false)

    assert reloaded.status == :active
  end

  test "an anonymous invitee sees sign-up/sign-in links carrying the org token", %{conn: conn} do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, member} =
      Organizations.invite_org_member(org.id, "new@example.com", actor: owner)

    {:ok, _lv, html} = live(conn, "/organizations/invite/#{member.invite_token}")
    assert html =~ "org_invite_token=#{member.invite_token}"
  end
end
