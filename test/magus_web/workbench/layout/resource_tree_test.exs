defmodule MagusWeb.Workbench.Layout.ResourceTreeTest do
  use MagusWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MagusWeb.Workbench.Layout.ResourceTree.{Section, Node}

  defmodule TestHost do
    use MagusWeb, :live_view

    alias MagusWeb.Workbench.Layout.ResourceTree

    @impl true
    def mount(_params, _session, socket) do
      sections = [
        %Section{
          key: :personal,
          label: "Personal",
          nodes: [
            Node.new_folder(
              id: "f1",
              label: "Drafts",
              icon: "lucide-folder",
              resource_type: :folder
            ),
            Node.new_leaf(
              id: "l1",
              label: "Hello world",
              icon: "lucide-messages-square",
              resource_type: :conversation
            )
          ]
        }
      ]

      {:ok,
       socket
       |> Phoenix.Component.assign(:sections, sections)
       |> Phoenix.Component.assign(:expanded_folders, %{})
       |> Phoenix.Component.assign(:auto_expanded_ids, MapSet.new())
       |> Phoenix.Component.assign(:editing_id, nil)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.live_component
        module={ResourceTree}
        id="test-tree"
        sections={@sections}
        expanded_folders={@expanded_folders}
        auto_expanded_ids={@auto_expanded_ids}
        editing_id={@editing_id}
      />
      """
    end
  end

  defmodule EmptyHost do
    use MagusWeb, :live_view

    alias MagusWeb.Workbench.Layout.ResourceTree
    alias MagusWeb.Workbench.Layout.ResourceTree.Section

    @impl true
    def mount(_, _, socket) do
      {:ok,
       socket
       |> Phoenix.Component.assign(:sections, [
         %Section{key: :empty, label: "Empty", nodes: [], empty_message: "Nothing here"}
       ])
       |> Phoenix.Component.assign(:expanded_folders, %{})
       |> Phoenix.Component.assign(:auto_expanded_ids, MapSet.new())
       |> Phoenix.Component.assign(:editing_id, nil)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.live_component
        module={ResourceTree}
        id="empty-tree"
        sections={@sections}
        expanded_folders={@expanded_folders}
        auto_expanded_ids={@auto_expanded_ids}
        editing_id={@editing_id}
      />
      """
    end
  end

  describe "ResourceTree" do
    test "renders section header and nodes", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, TestHost)

      assert html =~ "Personal"
      assert html =~ "test-tree-folder-f1"
      assert html =~ "Drafts"
      assert html =~ "test-tree-leaf-l1"
      assert html =~ "Hello world"
    end

    test "renders empty state when section has no nodes", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, EmptyHost)
      assert html =~ "Nothing here"
    end
  end
end
