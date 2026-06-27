defmodule Magus.Workspaces.ResourceAccessTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  defp create_folder(user) do
    {:ok, folder} =
      Magus.Chat.Folder
      |> Ash.Changeset.for_create(:create, %{name: "T"}, actor: user)
      |> Ash.create()

    folder
  end

  describe "grant" do
    test "creates a row with expected defaults" do
      user = generate(user())
      grantee = generate(user())
      folder = create_folder(user)

      {:ok, grant} =
        Workspaces.grant_access(
          %{
            resource_type: :folder,
            resource_id: folder.id,
            grantee_type: :user,
            grantee_id: grantee.id,
            role: :viewer
          },
          actor: user
        )

      assert grant.resource_type == :folder
      assert grant.resource_id == folder.id
      assert grant.grantee_type == :user
      assert grant.grantee_id == grantee.id
      assert grant.role == :viewer
      assert grant.granted_by_id == user.id
      assert %DateTime{} = grant.granted_at
    end
  end

  describe "uniqueness" do
    test "same (resource_type, resource_id, grantee_type, grantee_id) cannot be granted twice" do
      user = generate(user())
      grantee = generate(user())
      folder = create_folder(user)

      attrs = %{
        resource_type: :folder,
        resource_id: folder.id,
        grantee_type: :user,
        grantee_id: grantee.id,
        role: :viewer
      }

      {:ok, _first} = Workspaces.grant_access(attrs, actor: user)

      assert {:error, %Ash.Error.Invalid{} = err} =
               Workspaces.grant_access(attrs, actor: user)

      assert Exception.message(err) =~ ~r/has already been taken/
    end
  end

  describe "revoke" do
    test "destroys a grant and it's no longer fetchable" do
      user = generate(user())
      grantee = generate(user())
      folder = create_folder(user)

      {:ok, grant} =
        Workspaces.grant_access(
          %{
            resource_type: :folder,
            resource_id: folder.id,
            grantee_type: :user,
            grantee_id: grantee.id,
            role: :viewer
          },
          actor: user
        )

      :ok = Workspaces.revoke_access(grant, actor: user)

      assert {:error, _} = Ash.get(ResourceAccess, grant.id, actor: user)
    end
  end

  describe "resource types" do
    test ":skill is an accepted resource_type" do
      assert :skill in Magus.Workspaces.ResourceAccess.resource_types()
    end
  end
end
