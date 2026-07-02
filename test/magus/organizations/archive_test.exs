defmodule Magus.Organizations.ArchiveTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Organizations

  require Ash.Query

  # Captures every SeatSync callback so we can assert the archive fires the org
  # seam exactly once and never falls back to the per-member removal seam.
  defmodule TestSink do
    @behaviour Magus.Organizations.SeatSync
    @impl true
    def on_member_activated(id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:activated, id})
      :ok
    end

    @impl true
    def on_member_removed(id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:removed, id})
      :ok
    end

    @impl true
    def on_organization_archived(id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:organization_archived, id})
      :ok
    end

    @impl true
    def on_ownership_transferred(id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:ownership_transferred, id})
      :ok
    end
  end

  setup do
    Application.put_env(:magus, :seat_sync_test_pid, self())
    Application.put_env(:magus, Magus.Organizations.SeatSync, impl: TestSink)

    on_exit(fn ->
      Application.delete_env(:magus, Magus.Organizations.SeatSync)
      Application.delete_env(:magus, :seat_sync_test_pid)
    end)

    :ok
  end

  defp create_member(org, user) do
    Magus.Organizations.OrganizationMember
    |> Ash.Changeset.for_create(
      :create_member,
      %{organization_id: org.id, user_id: user.id, invite_email: to_string(user.email)},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp members(org_id) do
    Magus.Organizations.OrganizationMember
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end

  defp workspaces(org_id) do
    Magus.Workspaces.Workspace
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end

  test "owner archives: offboards members, deactivates workspaces, stamps archived_at, renames slug" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(%{name: "Acme", slug: "acme"}, actor: owner)

    member_user = generate(user())
    ensure_workspace_plan(member_user)
    member = create_member(org, member_user)

    {:ok, invited} = Organizations.invite_org_member(org.id, "invited@test.com", actor: owner)

    {:ok, archived} = Organizations.archive_organization(org, actor: owner)

    # archived_at stamped, slug renamed, original slug freed for reuse
    assert %DateTime{} = archived.archived_at
    assert archived.slug == "acme-archived-#{String.slice(org.id, 0, 6)}"
    refute archived.slug == "acme"

    # every membership (owner + member + invited) is :removed with removed_at
    all = members(org.id)
    assert length(all) == 3

    for m <- all do
      assert m.status == :removed
      assert %DateTime{} = m.removed_at
    end

    assert Enum.any?(all, &(&1.id == member.id))
    assert Enum.any?(all, &(&1.id == invited.id))

    # every org workspace is deactivated
    for ws <- workspaces(org.id) do
      refute ws.is_active
    end

    # the seam fires exactly once for the org and never per-member
    assert_receive {:organization_archived, org_id} when org_id == org.id
    refute_receive {:organization_archived, _}
    refute_receive {:removed, _}

    # the original slug is reusable by a fresh org
    reuser = generate(user())
    ensure_workspace_plan(reuser)

    assert {:ok, _fresh} =
             Organizations.create_organization(%{name: "Acme 2", slug: "acme"}, actor: reuser)
  end

  test "a member cannot archive the organization" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    member_user = generate(user())
    ensure_workspace_plan(member_user)
    create_member(org, member_user)

    assert {:error, %Ash.Error.Forbidden{}} =
             Organizations.archive_organization(org, actor: member_user)
  end

  test "archiving twice is rejected" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, archived} = Organizations.archive_organization(org, actor: owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Organizations.archive_organization(archived, actor: owner)
  end

  test "renaming an archived org is rejected" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, archived} = Organizations.archive_organization(org, actor: owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Organizations.update_organization(archived, %{name: "Renamed"}, actor: owner)
  end

  test "set_billing still works on an archived org" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, archived} = Organizations.archive_organization(org, actor: owner)

    assert {:ok, updated} =
             archived
             |> Ash.Changeset.for_update(:set_billing, %{billing_status: :canceled},
               actor: %Magus.SystemActor{}
             )
             |> Ash.update()

    assert updated.billing_status == :canceled
  end

  test "inviting into an archived org is rejected" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, _archived} = Organizations.archive_organization(org, actor: owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Organizations.invite_org_member(org.id, "late@test.com", actor: owner)
  end

  test "the archived slug stays within the 64-char cap for a max-length slug" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    # 64-char slug at the max_length boundary.
    long_slug = String.duplicate("a", 63) <> "b"
    assert String.length(long_slug) == 64

    {:ok, org} =
      Organizations.create_organization(%{name: "Long", slug: long_slug}, actor: owner)

    {:ok, archived} = Organizations.archive_organization(org, actor: owner)

    assert String.length(archived.slug) <= 64
    assert archived.slug =~ ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/
    assert String.ends_with?(archived.slug, "-archived-#{String.slice(org.id, 0, 6)}")
  end
end
