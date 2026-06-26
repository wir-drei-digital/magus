defmodule Magus.Workspaces.PoliciesTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Test.WorkspaceScopedFixture
  alias Magus.Workspaces.ResourceAccess

  # The fixture resource lives in its own `workspace_scoped_fixtures` table so
  # the AccessCheck `exists(ResourceAccess, ...)` filter can run. The table is
  # created inside the Ecto sandbox connection so it disappears on rollback.
  @create_table_sql """
  CREATE TABLE IF NOT EXISTS workspace_scoped_fixtures (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    workspace_id uuid NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    inserted_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
  )
  """

  setup do
    Ecto.Adapters.SQL.query!(Magus.Repo, @create_table_sql, [])

    creator = generate(user())
    stranger = generate(user())
    ensure_workspace_plan(creator)

    {:ok, workspace} =
      Magus.Workspaces.create_workspace(
        %{name: "T", slug: "t-#{System.unique_integer([:positive])}"},
        actor: creator
      )

    %{creator: creator, stranger: stranger, workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Grants are created with `authorize?: false` because our fixture's rows live
  # in `workspace_scoped_fixtures`, not in the `folders` table that
  # `ActorCanGrantResourceAccess` (the grant policy) looks up via
  # `resource_type: :folder`. The macro itself is tested by exercising
  # read/update/destroy paths below, which is what Task 7 covers.
  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, m} =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(
        :invite,
        %{
          workspace_id: workspace.id,
          invite_email: invitee.email
        },
        actor: admin_user
      )
      |> Ash.create()

    m
    |> Ash.Changeset.for_update(:accept, %{}, actor: invitee)
    |> Ash.update()
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "creator can read their own personal record", %{creator: creator} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X"}, actor: creator)
      |> Ash.create()

    assert {:ok, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: creator)
  end

  test "stranger cannot read a personal record", %{creator: creator, stranger: stranger} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X"}, actor: creator)
      |> Ash.create()

    assert {:error, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: stranger)
  end

  test "workspace-scoped record with no grant is creator-only",
       %{creator: creator, stranger: stranger, workspace: workspace} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X", workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    assert {:ok, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: creator)
    assert {:error, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: stranger)
  end

  test "workspace :viewer grant lets an active member read",
       %{creator: creator, stranger: stranger, workspace: workspace} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X", workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    {:ok, _member} = add_active_member(workspace, creator, stranger)

    _grant =
      grant!(%{
        resource_type: :folder,
        resource_id: record.id,
        grantee_type: :workspace,
        grantee_id: workspace.id,
        role: :viewer
      })

    assert {:ok, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: stranger)
  end

  test "direct user :viewer grant lets a non-member read",
       %{creator: creator, stranger: stranger, workspace: workspace} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X", workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    _grant =
      grant!(%{
        resource_type: :folder,
        resource_id: record.id,
        grantee_type: :user,
        grantee_id: stranger.id,
        role: :viewer
      })

    assert {:ok, _} = Ash.get(WorkspaceScopedFixture, record.id, actor: stranger)
  end

  test "direct user :editor grant lets update but not destroy",
       %{creator: creator, stranger: stranger, workspace: workspace} do
    {:ok, record} =
      WorkspaceScopedFixture
      |> Ash.Changeset.for_create(:create, %{name: "X", workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    _grant =
      grant!(%{
        resource_type: :folder,
        resource_id: record.id,
        grantee_type: :user,
        grantee_id: stranger.id,
        role: :editor
      })

    # Stranger can read (editor >= viewer)
    assert {:ok, loaded} = Ash.get(WorkspaceScopedFixture, record.id, actor: stranger)

    # Stranger can update (editor satisfies :editor min_role)
    assert {:ok, _} =
             loaded
             |> Ash.Changeset.for_update(:update, %{name: "Y"}, actor: stranger)
             |> Ash.update()

    # Stranger cannot destroy (destroy requires :owner)
    assert {:error, _} =
             loaded
             |> Ash.Changeset.for_destroy(:destroy, %{}, actor: stranger)
             |> Ash.destroy()
  end
end
