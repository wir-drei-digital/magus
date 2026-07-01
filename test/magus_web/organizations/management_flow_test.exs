defmodule MagusWeb.Organizations.ManagementFlowTest do
  @moduledoc """
  End-to-end happy path for the Organizations Management UI (phase 3).

  Drives the full owner + invitee lifecycle through the real backend actions
  the SPA calls, plus the Task 9 accept LiveView, asserting the end state:

    1. Owner creates an org.
    2. Owner invites a member by email.
    3. Invitee accepts via `/organizations/invite/:token` (Task 9 route);
       membership flips to `:active` AND the invitee is added to the org's
       shared workspace (a `WorkspaceMember` row).
    4. Owner lists members and sees the invitee active.
    5. Owner sets a per-member spend cap; a reload confirms the cap.
    6. Usage: after the invitee accrues spend, the owner sees pooled usage and
       both members, while the member sees only their own row.
    7. Billing overview: owner sees `billing_set_up == false`, `seat_count == 2`.

  This is an Elixir integration test (rather than a Playwright browser e2e)
  because a browser e2e needs the built SPA + a running server + a browser,
  which is not reliably runnable in this environment. It exercises the same
  actions the SPA invokes over RPC.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  require Ash.Query

  alias Magus.Organizations

  test "owner invites, invitee accepts, owner manages spend cap + sees usage/billing", %{
    conn: conn
  } do
    owner = generate(user())
    ensure_workspace_plan(owner)
    invitee = generate(user())
    ensure_workspace_plan(invitee)

    # 1. Owner creates an org (settings CTA).
    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    # 2. Owner invites a member by email.
    {:ok, member} =
      Organizations.invite_org_member(org.id, to_string(invitee.email), actor: owner)

    assert member.status == :invited

    # 3. Invitee accepts via the Task 9 accept LiveView, landing at the app root.
    invitee_conn = log_in_user(conn, invitee)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(invitee_conn, "/organizations/invite/#{member.invite_token}")

    {:ok, accepted} =
      Organizations.OrganizationMember |> Ash.get(member.id, authorize?: false)

    assert accepted.status == :active
    assert accepted.user_id == invitee.id

    # ...and the invitee was added to the org's shared workspace.
    shared =
      Magus.Workspaces.Workspace
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false)
      |> List.first()

    workspace_members =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Query.filter(workspace_id == ^shared.id and user_id == ^invitee.id)
      |> Ash.read!(authorize?: false)

    assert length(workspace_members) == 1

    # 4. Owner lists members and sees the invitee active.
    {:ok, members} = Organizations.list_org_members(org.id, actor: owner)
    invitee_member = Enum.find(members, &(&1.user_id == invitee.id))
    assert invitee_member
    assert invitee_member.status == :active

    # 5. Owner sets a per-member spend cap; a reload confirms it.
    {:ok, capped} =
      Organizations.set_member_spend_cap(accepted, %{spend_cap_cents: 5000}, actor: owner)

    assert capped.spend_cap_cents == 5000

    {:ok, reloaded_member} =
      Organizations.OrganizationMember |> Ash.get(member.id, authorize?: false)

    assert reloaded_member.spend_cap_cents == 5000

    # 6. Usage: accrue spend for the invitee, then check pooled + per-member views.
    {:ok, _sub} = Magus.Usage.get_user_subscription(invitee.id, authorize?: false)
    Magus.Usage.deduct_usage(invitee.id, 250, authorize?: false)

    {:ok, owner_usage} = Organizations.OrgUsage.for_organization(org.id, actor: owner)
    assert owner_usage.seat_count == 2
    assert owner_usage.pooled_spent_cents >= 250
    assert length(owner_usage.members) == 2

    {:ok, member_usage} = Organizations.OrgUsage.for_organization(org.id, actor: invitee)
    assert length(member_usage.members) == 1
    assert hd(member_usage.members).user_id == invitee.id

    # 7. Billing overview: no Stripe subscription set up yet, two seats.
    {:ok, overview} =
      Organizations.org_billing_overview(%{organization_id: org.id}, actor: owner)

    assert overview.billing_set_up == false
    assert overview.seat_count == 2
  end
end
