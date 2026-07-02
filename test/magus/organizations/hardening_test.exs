defmodule Magus.Organizations.HardeningTest do
  @moduledoc """
  Core hardening prerequisites (magus-gknz): system-actor bypasses, ownership
  transfer target validation, workspace deactivate org-owner clause, and
  paper-trail actor attribution for org bootstrap writes.
  """
  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

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

  defp add_active_member(org, user) do
    Magus.Organizations.OrganizationMember
    |> Ash.Changeset.for_create(:create_member, %{
      organization_id: org.id,
      user_id: user.id,
      invite_email: user.email
    })
    |> Ash.create!(authorize?: false)
  end

  # The owner-authorized policy is narrowed to `action(:update)`, so once the
  # system-actor bypasses fall through, set_billing / update_owner match no
  # policy and default-deny. Effective authorization: ONLY %Magus.SystemActor{}
  # may write billing/owner fields with authorize?: true.
  describe "system actor bypasses (set_billing / update_owner)" do
    test "even the org owner cannot set billing or repoint owner_id" do
      owner = generate(user())
      org = make_org(owner)
      new_owner = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               org
               |> Ash.Changeset.for_update(:set_billing, %{billing_status: :past_due},
                 actor: owner
               )
               |> Ash.update(authorize?: true)

      assert {:error, %Ash.Error.Forbidden{}} =
               org
               |> Ash.Changeset.for_update(:update_owner, %{owner_id: new_owner.id}, actor: owner)
               |> Ash.update(authorize?: true)
    end

    test "the org owner can still rename via the plain :update action" do
      owner = generate(user())
      org = make_org(owner)

      assert {:ok, renamed} =
               org
               |> Ash.Changeset.for_update(:update, %{name: "Renamed Org"}, actor: owner)
               |> Ash.update(authorize?: true)

      assert renamed.name == "Renamed Org"
    end

    test "a plain member cannot set billing, but the system actor can" do
      owner = generate(user())
      org = make_org(owner)
      member_user = generate(user())
      add_active_member(org, member_user)

      assert {:error, %Ash.Error.Forbidden{}} =
               org
               |> Ash.Changeset.for_update(:set_billing, %{billing_status: :past_due},
                 actor: member_user
               )
               |> Ash.update(authorize?: true)

      assert {:ok, updated} =
               org
               |> Ash.Changeset.for_update(:set_billing, %{billing_status: :past_due},
                 actor: %Magus.SystemActor{}
               )
               |> Ash.update(authorize?: true)

      assert updated.billing_status == :past_due
    end

    test "a plain member cannot repoint owner_id, but the system actor can" do
      owner = generate(user())
      org = make_org(owner)
      member_user = generate(user())
      add_active_member(org, member_user)
      new_owner = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               org
               |> Ash.Changeset.for_update(:update_owner, %{owner_id: new_owner.id},
                 actor: member_user
               )
               |> Ash.update(authorize?: true)

      assert {:ok, updated} =
               org
               |> Ash.Changeset.for_update(:update_owner, %{owner_id: new_owner.id},
                 actor: %Magus.SystemActor{}
               )
               |> Ash.update(authorize?: true)

      assert updated.owner_id == new_owner.id
    end
  end

  describe "transfer_ownership target validation" do
    test "cannot transfer to an invited (not-yet-active) member" do
      owner = generate(user())
      org = make_org(owner)
      {:ok, invite} = Organizations.invite_org_member(org.id, "pending@test.com", actor: owner)

      assert {:error, error} = Organizations.transfer_org_ownership(invite, actor: owner)
      assert Exception.message(error) =~ "ownership can only transfer to an active member"
    end

    test "cannot transfer ownership to yourself" do
      owner = generate(user())
      org = make_org(owner)

      owner_member =
        Magus.Organizations.OrganizationMember
        |> Ash.Query.filter(organization_id == ^org.id and role == :owner)
        |> Ash.read_one!(authorize?: false)

      assert {:error, error} = Organizations.transfer_org_ownership(owner_member, actor: owner)
      assert Exception.message(error) =~ "you already own this organization"
    end

    test "transfer to an active member still succeeds" do
      owner = generate(user())
      org = make_org(owner)
      member_user = generate(user())
      member = add_active_member(org, member_user)

      assert {:ok, promoted} = Organizations.transfer_org_ownership(member, actor: owner)
      assert promoted.role == :owner
    end
  end

  describe "workspace deactivate org-owner clause" do
    test "an org owner can deactivate an org-owned workspace they are not a member of" do
      org_owner = generate(user())
      org = make_org(org_owner)

      # A workspace created and admined by someone else, then tagged to the org.
      ws_admin = generate(user())
      ensure_workspace_plan(ws_admin)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Sub", slug: "sub-ws-#{System.unique_integer([:positive])}"},
          actor: ws_admin
        )

      workspace =
        workspace
        |> Ash.Changeset.for_update(:set_organization, %{organization_id: org.id},
          authorize?: false
        )
        |> Ash.update!()

      # org_owner is not a member of this workspace, but owns the org.
      assert {:ok, deactivated} =
               Magus.Workspaces.deactivate_workspace(workspace, actor: org_owner)

      assert deactivated.is_active == false
    end

    test "a plain user (no admin membership, not the org owner) cannot deactivate" do
      org_owner = generate(user())
      org = make_org(org_owner)

      ws_admin = generate(user())
      ensure_workspace_plan(ws_admin)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Sub", slug: "sub-ws-#{System.unique_integer([:positive])}"},
          actor: ws_admin
        )

      workspace =
        workspace
        |> Ash.Changeset.for_update(:set_organization, %{organization_id: org.id},
          authorize?: false
        )
        |> Ash.update!()

      stranger = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Workspaces.deactivate_workspace(workspace, actor: stranger)
    end
  end

  describe "paper-trail actor attribution on org bootstrap" do
    test "the organization create version carries the creating user via owner_id" do
      creator = generate(user())
      org = make_org(creator)

      create_version =
        Magus.Organizations.Organization.Version
        |> Ash.Query.filter(version_source_id == ^org.id)
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.version_action_type == :create))

      assert create_version
      assert create_version.owner_id == creator.id
    end

    test "the bootstrapped owner-member version carries the creating user via user_id" do
      creator = generate(user())
      org = make_org(creator)

      owner_member =
        Magus.Organizations.OrganizationMember
        |> Ash.Query.filter(organization_id == ^org.id and role == :owner)
        |> Ash.read_one!(authorize?: false)

      member_version =
        Magus.Organizations.OrganizationMember.Version
        |> Ash.Query.filter(version_source_id == ^owner_member.id)
        |> Ash.read!(authorize?: false)
        |> Enum.find(&(&1.version_action_type == :create))

      assert member_version
      assert member_version.user_id == creator.id
    end
  end
end
