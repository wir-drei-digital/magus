defmodule MagusWeb.Workbench.Detail.WorkspaceSettingsView do
  @moduledoc """
  Workspace settings detail view (General). Members and Usage are sibling
  detail views at WorkspaceMembersView and WorkspaceUsageView.
  """
  use MagusWeb, :live_view

  on_mount({MagusWeb.LiveUserAuth, :restore_locale})

  @impl true
  def mount(_params, %{"slug" => slug, "user_id" => user_id}, socket) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    socket =
      socket
      |> assign(:current_user, user)
      |> MagusWeb.WorkspaceLive.Settings.init_assigns(slug, user)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto" data-detail-view="workspace_settings">
      <div class="container mx-auto max-w-4xl py-8 px-4">
        {MagusWeb.WorkspaceLive.Settings.render_settings_section(assigns)}
      </div>
    </div>
    """
  end

  @impl true
  def handle_event(event, params, socket),
    do: MagusWeb.WorkspaceLive.Settings.handle_event(event, params, socket)

  @impl true
  def handle_info(msg, socket),
    do: MagusWeb.WorkspaceLive.Settings.handle_info(msg, socket)
end
