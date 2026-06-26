defmodule MagusWeb.ChatLive.Components.Brain.BrainFilePickerModalComponentTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias MagusWeb.ChatLive.Components.Brain.BrainFilePickerModalComponent
  alias Magus.Brain
  alias Magus.Files

  setup do
    user = generate(user())
    ensure_workspace_plan(user)
    workspace = generate(workspace(actor: user))
    {:ok, brain} = Brain.create_brain(%{title: "B", workspace_id: workspace.id}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, workspace: workspace, brain: brain, page: page}
  end

  defp create_file(user, attrs) do
    Files.create_file(
      Map.merge(
        %{
          name: "doc.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1024,
          file_path: "tmp/doc.pdf"
        },
        attrs
      ),
      actor: user
    )
  end

  test "lists same-scope files and excludes mismatched workspace files", %{
    user: user,
    workspace: workspace,
    brain: brain,
    page: page
  } do
    {:ok, _my_file} = create_file(user, %{name: "mine.pdf", workspace_id: workspace.id})

    other_workspace = generate(workspace(actor: user))
    {:ok, _other_file} = create_file(user, %{name: "other.pdf", workspace_id: other_workspace.id})

    html =
      render_component(BrainFilePickerModalComponent,
        id: "picker",
        current_user: user,
        brain: brain,
        page: page
      )

    assert html =~ "mine.pdf"
    refute html =~ "other.pdf"
  end

  test "excludes personal files when brain has a workspace", %{
    user: user,
    brain: brain,
    page: page
  } do
    {:ok, _personal_file} = create_file(user, %{name: "personal.pdf", workspace_id: nil})

    html =
      render_component(BrainFilePickerModalComponent,
        id: "picker",
        current_user: user,
        brain: brain,
        page: page
      )

    refute html =~ "personal.pdf"
    assert html =~ "No files in this scope."
  end

  test "renders Browse and Upload tabs with Browse active by default", %{
    user: user,
    brain: brain,
    page: page
  } do
    html =
      render_component(BrainFilePickerModalComponent,
        id: "picker",
        current_user: user,
        brain: brain,
        page: page
      )

    assert html =~ "Browse"
    assert html =~ "Upload"
    # Browse content visible by default
    assert html =~ "Filter by name"
    # Upload content not yet rendered
    refute html =~ "Drop files here or click to choose"
  end
end
