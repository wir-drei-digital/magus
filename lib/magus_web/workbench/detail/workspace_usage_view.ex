defmodule MagusWeb.Workbench.Detail.WorkspaceUsageView do
  @moduledoc """
  Workspace usage detail view. Sibling to WorkspaceSettingsView and
  WorkspaceMembersView.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  @impl true
  def mount(_params, %{"slug" => slug, "user_id" => user_id}, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    socket =
      socket
      |> assign(:current_user, user)
      |> MagusWeb.WorkspaceLive.Usage.init_assigns(slug, user)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto" data-detail-view="workspace_usage">
      <div class="container mx-auto max-w-4xl py-8 px-4">
        {MagusWeb.WorkspaceLive.Usage.render_usage_section(assigns)}
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(msg, socket),
    do: MagusWeb.WorkspaceLive.Usage.handle_info(msg, socket)
end
