defmodule Magus.Knowledge.KnowledgeCollectionWorkspaceTest do
  @moduledoc """
  Tests for the workspace-scoped policy on `Magus.Knowledge.KnowledgeCollection`
  backed by `Magus.Workspaces.ResourceAccess` grants, including materialization
  of `workspace_id` from the parent `KnowledgeSource` on create, and destroy
  grant cleanup.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Knowledge
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

  defp grants_for(collection) do
    ResourceAccess
    |> Ash.Query.for_read(:for_resource, %{
      resource_type: :knowledge_collection,
      resource_id: collection.id
    })
    |> Ash.read!(authorize?: false)
  end

  defp create_workspace_source!(user, workspace) do
    {:ok, source} =
      Knowledge.create_source(
        %{
          name: "Team Notion",
          provider: :notion,
          auth_config: %{"api_key" => "test_key"},
          workspace_id: workspace.id
        },
        actor: user
      )

    source
  end

  defp create_personal_source!(user) do
    {:ok, source} =
      Knowledge.create_source(
        %{
          name: "Personal",
          provider: :notion,
          auth_config: %{"api_key" => "test_key"}
        },
        actor: user
      )

    source
  end

  describe "workspace_id materialization on create" do
    test "inherits workspace_id from parent KnowledgeSource" do
      creator = generate(user())
      ensure_workspace_plan(creator)
      workspace = generate(workspace(actor: creator))
      source = create_workspace_source!(creator, workspace)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "Engineering", external_id: "ext_eng", external_path: "/eng"},
          actor: creator
        )

      assert collection.workspace_id == workspace.id
    end

    test "leaves workspace_id nil when parent KnowledgeSource has none" do
      creator = generate(user())
      source = create_personal_source!(creator)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "Notes", external_id: "ext_notes", external_path: "/notes"},
          actor: creator
        )

      assert is_nil(collection.workspace_id)
    end
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)
      workspace = generate(workspace(actor: creator))
      source = create_workspace_source!(creator, workspace)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "WS", external_id: "ext_ws", external_path: "/ws"},
          actor: creator
        )

      %{
        creator: creator,
        stranger: stranger,
        workspace: workspace,
        source: source,
        collection: collection
      }
    end

    test "creator (source owner) can always read the collection", %{
      creator: creator,
      collection: collection
    } do
      assert {:ok, _} = Knowledge.get_collection(collection.id, actor: creator)
    end

    test "stranger cannot read a workspace collection", %{
      stranger: stranger,
      collection: collection
    } do
      assert {:error, _} = Knowledge.get_collection(collection.id, actor: stranger)
    end

    test "active workspace member cannot read without a grant (Path B default)", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace,
      collection: collection
    } do
      _ = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Knowledge.get_collection(collection.id, actor: stranger)
    end

    test "workspace :viewer grant makes the collection visible to active members", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace,
      collection: collection
    } do
      _ = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :knowledge_collection,
          resource_id: collection.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Knowledge.get_collection(collection.id, actor: stranger)
    end
  end

  describe "destroy grant cleanup" do
    test "destroying a collection cleans up its ResourceAccess grants" do
      creator = generate(user())
      ensure_workspace_plan(creator)
      workspace = generate(workspace(actor: creator))
      source = create_workspace_source!(creator, workspace)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "To destroy", external_id: "ext_del", external_path: "/del"},
          actor: creator
        )

      _grant =
        grant!(%{
          resource_type: :knowledge_collection,
          resource_id: collection.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert length(grants_for(collection)) == 1

      :ok = Knowledge.destroy_collection(collection, actor: creator)

      assert grants_for(collection) == []
    end
  end

  describe "is_shared_to_workspace calculation" do
    test "is true when workspace grant exists" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      source = create_workspace_source!(user, ws)

      {:ok, coll} =
        Knowledge.create_collection(
          source.id,
          %{name: "c", external_id: "x", external_path: "/c"},
          actor: user
        )

      {:ok, _grant} =
        Workspaces.grant_access(
          %{
            resource_type: :knowledge_collection,
            resource_id: coll.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: user
        )

      {:ok, loaded} =
        Knowledge.get_collection(coll.id, actor: user, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == true
    end
  end

  describe "list_for_workspace + personal_collections" do
    test "list_for_workspace returns workspace collections with calc loaded" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      source = create_workspace_source!(user, ws)

      {:ok, coll} =
        Knowledge.create_collection(
          source.id,
          %{name: "wc", external_id: "w", external_path: "/wc"},
          actor: user
        )

      {:ok, items} = Knowledge.list_workspace_collections(ws.id, actor: user)
      assert Enum.map(items, & &1.id) == [coll.id]
      assert Enum.all?(items, &(&1.is_shared_to_workspace == false))
    end

    test "personal_collections returns no-workspace collections" do
      user = generate(user())
      source = create_personal_source!(user)

      {:ok, coll} =
        Knowledge.create_collection(
          source.id,
          %{name: "pc", external_id: "p", external_path: "/pc"},
          actor: user
        )

      {:ok, items} = Knowledge.list_personal_collections(actor: user)
      assert Enum.any?(items, &(&1.id == coll.id))
    end
  end
end
