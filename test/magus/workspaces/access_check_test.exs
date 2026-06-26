defmodule Magus.Workspaces.AccessCheckTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Workspaces.AccessCheck
  alias Magus.Workspaces.ResourceAccess

  setup do
    user = generate(user())
    grantee = generate(user())
    ensure_workspace_plan(user)

    {:ok, workspace} =
      Magus.Workspaces.create_workspace(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: user
      )

    {:ok, gm} =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(
        :invite,
        %{
          workspace_id: workspace.id,
          invite_email: grantee.email
        },
        actor: user
      )
      |> Ash.create()

    {:ok, _} =
      gm
      |> Ash.Changeset.for_update(:accept, %{}, actor: grantee)
      |> Ash.update()

    %{user: user, grantee: grantee, workspace: workspace}
  end

  test "direct user grant authorizes at matching role or below", %{
    user: user,
    grantee: grantee
  } do
    {:ok, folder} =
      Magus.Chat.Folder
      |> Ash.Changeset.for_create(:create, %{name: "T"}, actor: user)
      |> Ash.create()

    resource_id = folder.id

    {:ok, _} =
      ResourceAccess
      |> Ash.Changeset.for_create(
        :grant,
        %{
          resource_type: :folder,
          resource_id: resource_id,
          grantee_type: :user,
          grantee_id: grantee.id,
          role: :editor
        },
        actor: user
      )
      |> Ash.create()

    assert AccessCheck.has_access?(:folder, resource_id, grantee, :viewer)
    assert AccessCheck.has_access?(:folder, resource_id, grantee, :editor)
    refute AccessCheck.has_access?(:folder, resource_id, grantee, :owner)
  end

  test "workspace grant authorizes any active member", %{
    user: user,
    workspace: workspace,
    grantee: grantee
  } do
    {:ok, folder} =
      Magus.Chat.Folder
      |> Ash.Changeset.for_create(:create, %{name: "T"}, actor: user)
      |> Ash.create()

    resource_id = folder.id

    {:ok, _} =
      ResourceAccess
      |> Ash.Changeset.for_create(
        :grant,
        %{
          resource_type: :folder,
          resource_id: resource_id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        },
        actor: user
      )
      |> Ash.create()

    assert AccessCheck.has_access?(:folder, resource_id, grantee, :viewer)
    refute AccessCheck.has_access?(:folder, resource_id, grantee, :editor)
  end

  test "non-grantee gets no access" do
    stranger = generate(user())
    resource_id = Ash.UUID.generate()

    refute AccessCheck.has_access?(:folder, resource_id, stranger, :viewer)
  end
end
