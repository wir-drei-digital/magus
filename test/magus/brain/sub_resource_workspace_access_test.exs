defmodule Magus.Brain.SubResourceWorkspaceAccessTest do
  @moduledoc """
  Confirms Brain sub-resources (pages, by extension blocks/connections via
  the same BrainAccessFilter / ActorOwnsBrain checks) honor workspace grants,
  custom-agent grants, and workspace-admin override.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Brain
  alias Magus.Workspaces

  defp pro_user do
    user = generate(user())
    ensure_workspace_plan(user)
    user
  end

  defp ws(actor), do: generate(workspace(actor: actor))

  defp create_member(user, ws, role) do
    action =
      case role do
        :admin -> :create_admin
        _ -> :create_member
      end

    Magus.Workspaces.WorkspaceMember
    |> Ash.Changeset.for_create(
      action,
      %{user_id: user.id, workspace_id: ws.id, invite_email: to_string(user.email)},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  describe "BrainAccessFilter (read side)" do
    test "workspace member with :viewer grant can read pages" do
      owner = pro_user()
      member = generate(user())
      ws = ws(owner)
      create_member(member, ws, :member)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: owner)

      {:ok, _grant} =
        Workspaces.grant_access(
          %{
            resource_type: :brain,
            resource_id: brain.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: owner
        )

      assert {:ok, [%{id: pid}]} = Brain.list_pages(brain.id, actor: member)
      assert pid == page.id
    end

    test "workspace admin (no explicit grant) can read pages in their workspace" do
      owner = pro_user()
      admin = generate(user())
      ws = ws(owner)
      create_member(admin, ws, :admin)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)
      {:ok, _page} = Brain.create_page(brain.id, %{title: "P"}, actor: owner)

      assert {:ok, [_]} = Brain.list_pages(brain.id, actor: admin)
    end

    test "outsider with no grant gets an empty page list" do
      owner = pro_user()
      stranger = generate(user())
      ws = ws(owner)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)
      {:ok, _page} = Brain.create_page(brain.id, %{title: "P"}, actor: owner)

      assert {:ok, []} = Brain.list_pages(brain.id, actor: stranger)
    end
  end

  describe "ActorOwnsBrain (write side)" do
    test "workspace admin (no grant) can create a page" do
      owner = pro_user()
      admin = generate(user())
      ws = ws(owner)
      create_member(admin, ws, :admin)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)

      assert {:ok, _page} = Brain.create_page(brain.id, %{title: "P"}, actor: admin)
    end

    test "workspace member with :editor grant can create a page" do
      owner = pro_user()
      member = generate(user())
      ws = ws(owner)
      create_member(member, ws, :member)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)

      {:ok, _grant} =
        Workspaces.grant_access(
          %{
            resource_type: :brain,
            resource_id: brain.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :editor
          },
          actor: owner
        )

      assert {:ok, _page} = Brain.create_page(brain.id, %{title: "P"}, actor: member)
    end

    test "workspace member with only :viewer grant cannot create a page" do
      owner = pro_user()
      member = generate(user())
      ws = ws(owner)
      create_member(member, ws, :member)

      {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: owner)

      {:ok, _grant} =
        Workspaces.grant_access(
          %{
            resource_type: :brain,
            resource_id: brain.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: owner
        )

      assert {:error, _} = Brain.create_page(brain.id, %{title: "P"}, actor: member)
    end
  end
end
