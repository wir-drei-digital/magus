defmodule Magus.Workspaces.ImplicitSharesBackfillTest do
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Workspaces.ResourceAccess

  # Minimal valid PNG (1x1 transparent pixel)
  @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
                 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
                 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
                 0x60, 0x82>>

  defp create_temp_file(content) do
    path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(1_000_000)}")
    Elixir.File.write!(path, content)
    path
  end

  defp make_workspace!(creator) do
    ensure_workspace_plan(creator)

    {:ok, workspace} =
      Magus.Workspaces.create_workspace(
        %{name: "W", slug: "w-#{System.unique_integer([:positive])}"},
        actor: creator
      )

    workspace
  end

  defp strip_grants!(resource_type, resource_id) do
    ResourceAccess
    |> Ash.Query.filter(resource_type == ^resource_type and resource_id == ^resource_id)
    |> Ash.bulk_destroy!(:revoke, %{}, authorize?: false)

    :ok
  end

  defp grants_for(resource_type, resource_id) do
    ResourceAccess
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      resource_type == ^resource_type and
        resource_id == ^resource_id and
        grantee_type == :workspace
    )
    |> Ash.read!(authorize?: false)
  end

  test "prompts with workspace_id get a workspace :viewer grant" do
    creator = generate(user())
    workspace = make_workspace!(creator)

    {:ok, prompt} =
      Magus.Library.Prompt
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "P",
          content: "x",
          type: :user,
          workspace_id: workspace.id
        },
        actor: creator
      )
      |> Ash.create()

    :ok = strip_grants!(:prompt, prompt.id)

    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()

    grants = grants_for(:prompt, prompt.id)
    assert length(grants) == 1
    [grant] = grants
    assert grant.role == :viewer
    assert grant.grantee_id == workspace.id
  end

  test "custom_agents with workspace_id get a workspace :viewer grant" do
    creator = generate(user())
    workspace = make_workspace!(creator)

    {:ok, agent} =
      Magus.Agents.CustomAgent
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "A",
          workspace_id: workspace.id
        },
        actor: creator
      )
      |> Ash.create()

    :ok = strip_grants!(:custom_agent, agent.id)

    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()

    grants = grants_for(:custom_agent, agent.id)
    assert length(grants) == 1
    [grant] = grants
    assert grant.role == :viewer
    assert grant.grantee_id == workspace.id
  end

  test "files with workspace_id get a workspace :viewer grant" do
    creator = generate(user())
    workspace = make_workspace!(creator)

    path = create_temp_file(@png_content)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "f.png",
          type: :image,
          mime_type: "image/png",
          file_size: byte_size(@png_content),
          file_path: path,
          workspace_id: workspace.id
        },
        actor: creator
      )

    :ok = strip_grants!(:file, file.id)

    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()

    grants = grants_for(:file, file.id)
    assert length(grants) == 1
    [grant] = grants
    assert grant.role == :viewer
    assert grant.grantee_id == workspace.id
  end

  test "backfill is idempotent across targets" do
    creator = generate(user())
    workspace = make_workspace!(creator)

    {:ok, prompt} =
      Magus.Library.Prompt
      |> Ash.Changeset.for_create(
        :create,
        %{name: "P", content: "x", type: :user, workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    {:ok, agent} =
      Magus.Agents.CustomAgent
      |> Ash.Changeset.for_create(
        :create,
        %{name: "A", workspace_id: workspace.id},
        actor: creator
      )
      |> Ash.create()

    path = create_temp_file(@png_content)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "f.png",
          type: :image,
          mime_type: "image/png",
          file_size: byte_size(@png_content),
          file_path: path,
          workspace_id: workspace.id
        },
        actor: creator
      )

    :ok = strip_grants!(:prompt, prompt.id)
    :ok = strip_grants!(:custom_agent, agent.id)
    :ok = strip_grants!(:file, file.id)

    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()
    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()

    for {type, id} <- [{:prompt, prompt.id}, {:custom_agent, agent.id}, {:file, file.id}] do
      assert length(grants_for(type, id)) == 1
    end
  end

  test "soft-deleted files are not backfilled" do
    creator = generate(user())
    workspace = make_workspace!(creator)

    path = create_temp_file(@png_content)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "f.png",
          type: :image,
          mime_type: "image/png",
          file_size: byte_size(@png_content),
          file_path: path,
          workspace_id: workspace.id
        },
        actor: creator
      )

    {:ok, _} =
      file
      |> Ash.Changeset.for_update(:soft_delete, %{}, actor: creator)
      |> Ash.update()

    # soft_delete should also clean up grants; ensure the test drives the
    # backfill against a deleted-but-still-present row.
    :ok = strip_grants!(:file, file.id)

    Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()

    assert grants_for(:file, file.id) == []
  end
end
