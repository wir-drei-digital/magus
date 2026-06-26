defmodule MagusWeb.Workbench.Modes.PromptsModeNav do
  @moduledoc """
  Prompts mode nav. Renders prompts as leaf nodes via the shared
  `ResourceTree` component.

  Personal workspace: a single section of the actor's no-workspace
  prompts. Regular workspace: workspace-scoped prompts split into
  Shared and Personal.

  Clicking a prompt emits `select_detail` to the parent LV; prompts
  don't open as tabs in v1.
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Modes.PromptsModeNav.Data

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    sections =
      Data.load_sections(%{
        user: socket.assigns.current_user,
        workspace_id: socket.assigns.workspace_id,
        search_query: socket.assigns[:search_query] || "",
        nav_filter: socket.assigns[:nav_filter] || :all,
        tree_target: socket.assigns.myself,
        current_chat_conv_id: socket.assigns[:current_chat_conv_id]
      })

    {:ok, assign(socket, :sections, sections)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={MagusWeb.Workbench.Layout.ResourceTree}
        id={"#{@id}-tree"}
        sections={@sections}
        expanded_folders={%{}}
        auto_expanded_ids={MapSet.new()}
        editing_id={nil}
      />
    </div>
    """
  end
end
