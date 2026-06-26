defmodule Magus.Workspaces.ResourceAccessPolicyTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Workspaces.ResourceAccess

  setup do
    creator = generate(user())
    stranger = generate(user())

    {:ok, folder} =
      Magus.Chat.Folder
      |> Ash.Changeset.for_create(:create, %{name: "Test"}, actor: creator)
      |> Ash.create()

    %{creator: creator, stranger: stranger, folder: folder}
  end

  test "creator can grant access", %{creator: creator, folder: folder} do
    grantee = generate(user())

    assert {:ok, _} =
             ResourceAccess
             |> Ash.Changeset.for_create(
               :grant,
               %{
                 resource_type: :folder,
                 resource_id: folder.id,
                 grantee_type: :user,
                 grantee_id: grantee.id,
                 role: :viewer
               },
               actor: creator
             )
             |> Ash.create()
  end

  test "stranger cannot grant access", %{stranger: stranger, folder: folder} do
    grantee = generate(user())

    assert {:error, %Ash.Error.Forbidden{}} =
             ResourceAccess
             |> Ash.Changeset.for_create(
               :grant,
               %{
                 resource_type: :folder,
                 resource_id: folder.id,
                 grantee_type: :user,
                 grantee_id: grantee.id,
                 role: :viewer
               },
               actor: stranger
             )
             |> Ash.create()
  end

  test "grantee can read their own grant via grantee_type == :user shortcut",
       %{creator: creator, folder: folder} do
    grantee = generate(user())

    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(
        :grant,
        %{
          resource_type: :folder,
          resource_id: folder.id,
          grantee_type: :user,
          grantee_id: grantee.id,
          role: :viewer
        },
        actor: creator
      )
      |> Ash.create()

    require Ash.Query

    {:ok, rows} =
      ResourceAccess
      |> Ash.Query.filter(id == ^grant.id)
      |> Ash.read(actor: grantee)

    assert Enum.map(rows, & &1.id) == [grant.id]
  end
end
