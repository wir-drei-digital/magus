defmodule Magus.Brain.BrainWorkspaceTest do
  @moduledoc """
  Tests for the generic workspace-scoped policy on `Magus.Brain.BrainResource`
  backed by `Magus.Workspaces.ResourceAccess` grants. Also covers destroy
  grant cleanup.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Brain
  alias Magus.Brain.BrainResource
  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  require Ash.Query

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} =
      Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)

    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  defp grants_for(brain) do
    ResourceAccess
    |> Ash.Query.for_read(:for_resource, %{resource_type: :brain, resource_id: brain.id})
    |> Ash.read!(authorize?: false)
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-brain-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, stranger: stranger, workspace: workspace}
    end

    test "creator can read their own personal brain", %{creator: creator} do
      {:ok, brain} = Brain.create_brain(%{title: "Personal"}, actor: creator)

      assert is_nil(brain.workspace_id)
      assert {:ok, _} = Brain.get_brain(brain.id, actor: creator)
    end

    test "creator can read their own workspace brain", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      assert brain.workspace_id == workspace.id
      assert {:ok, _} = Brain.get_brain(brain.id, actor: creator)
    end

    test "stranger cannot read a personal brain", %{creator: creator, stranger: stranger} do
      {:ok, brain} = Brain.create_brain(%{title: "Personal"}, actor: creator)

      assert {:error, _} = Brain.get_brain(brain.id, actor: stranger)
    end

    test "stranger cannot read a workspace brain", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      assert {:error, _} = Brain.get_brain(brain.id, actor: stranger)
    end

    test "active workspace member does NOT see workspace brain without a grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      _ = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Brain.get_brain(brain.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read the brain", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      _ = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :brain,
          resource_id: brain.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Brain.get_brain(brain.id, actor: stranger)
    end
  end

  describe "destroy grant cleanup" do
    test "destroying a brain cleans up its ResourceAccess grants" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-braindestroy-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, brain} =
        Brain.create_brain(
          %{title: "To Destroy", workspace_id: workspace.id},
          actor: creator
        )

      _grant =
        grant!(%{
          resource_type: :brain,
          resource_id: brain.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert length(grants_for(brain)) == 1

      :ok = Brain.destroy_brain(brain, actor: creator)

      assert grants_for(brain) == []
    end
  end

  describe "list actions" do
    setup do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-brainlist-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, workspace: workspace}
    end

    test "list_for_user returns only personal brains", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, personal} = Brain.create_brain(%{title: "Personal"}, actor: creator)

      {:ok, _ws_brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      {:ok, brains} = Brain.list_brains(actor: creator)

      assert length(brains) == 1
      assert hd(brains).id == personal.id
    end

    test "list_for_workspace returns only that workspace's brains", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, _personal} = Brain.create_brain(%{title: "Personal"}, actor: creator)

      {:ok, ws_brain} =
        Brain.create_brain(%{title: "WS Brain", workspace_id: workspace.id}, actor: creator)

      {:ok, brains} =
        BrainResource
        |> Ash.Query.for_read(:list_for_workspace, %{workspace_id: workspace.id}, actor: creator)
        |> Ash.read()

      assert length(brains) == 1
      assert hd(brains).id == ws_brain.id
    end
  end
end
