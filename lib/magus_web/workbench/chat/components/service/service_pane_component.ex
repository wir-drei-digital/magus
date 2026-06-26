defmodule MagusWeb.ChatLive.Components.Service.ServicePaneComponent do
  @moduledoc """
  Live component for rendering a sandbox service preview in the side pane.

  Displays an iframe pointing to the sandbox preview URL with controls
  for opening in a new tab and closing the pane. When the sandbox is
  suspended or stopped, shows a reload button to restart the service.

  The reload event is handled by the parent LiveView since LiveComponents
  cannot receive async messages.
  """

  use MagusWeb, :live_component
  use Gettext, backend: MagusWeb.Gettext

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="service-pane"
      class="flex flex-col h-full border-l border-base-300 bg-base-100 relative"
      phx-hook="ServiceCapture"
    >
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 border-b border-base-300 bg-base-100/80 backdrop-blur-sm relative z-10">
        <div class="flex items-center gap-2 min-w-0 pr-2">
          <.icon name="lucide-globe" class="w-4 h-4 text-success flex-shrink-0" />
          <h3 class="font-medium text-sm truncate">{gettext("Service Preview")}</h3>
          <span class={["badge badge-xs", status_badge_class(@service.status)]}>
            {@service.status}
          </span>
        </div>
        <div class="flex items-center gap-1">
          <button
            :if={@service.status == "running"}
            type="button"
            phx-click="toggle_service_capture"
            class={[
              "btn btn-ghost btn-xs btn-circle",
              if(@capture_mode, do: "btn-active text-primary")
            ]}
            title={
              if @capture_mode, do: gettext("Exit screenshot mode"), else: gettext("Take screenshot")
            }
          >
            <.icon name="lucide-camera" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="reload_service"
            class={["btn btn-ghost btn-xs gap-1", if(@reloading, do: "btn-disabled")]}
            title={gettext("Reload service")}
            disabled={@reloading}
          >
            <.icon
              name="lucide-refresh-cw"
              class={["w-3.5 h-3.5", if(@reloading, do: "animate-spin")]}
            />
          </button>
          <a
            :if={@service.status == "running"}
            href={@service.preview_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-ghost btn-xs gap-1"
            title={gettext("Open in new tab")}
          >
            <.icon name="lucide-external-link" class="w-3.5 h-3.5" />
          </a>
          <button
            type="button"
            phx-click="close_pane"
            class="btn btn-ghost btn-xs btn-circle"
            title={gettext("Close")}
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <%!-- Service name subheader --%>
      <div
        :if={@service.name && @service.name != "service"}
        class="px-4 py-1.5 border-b border-base-300 bg-base-200/30"
      >
        <span class="text-xs text-base-content/60">{@service.name}</span>
      </div>

      <%!-- Content area --%>
      <%= if @service.status == "running" do %>
        <div class="flex-1 overflow-hidden service-capture-area">
          <iframe
            id="service-preview-iframe"
            src={@service.preview_url}
            class="w-full h-full bg-white"
            sandbox="allow-scripts allow-forms allow-same-origin allow-popups"
            title={"Service preview: #{@service.name}"}
          />
        </div>
      <% else %>
        <div class="flex-1 flex items-center justify-center">
          <div class="text-center space-y-3 px-4">
            <.icon name="lucide-cloud-off" class="w-10 h-10 text-base-content/30 mx-auto" />
            <p class="text-sm text-base-content/60">
              <%= if @reloading do %>
                {gettext("Waking up sandbox...")}
              <% else %>
                {gettext("The sandbox has been suspended.")}
              <% end %>
            </p>
            <button
              :if={!@reloading}
              type="button"
              phx-click="reload_service"
              class="btn btn-sm btn-primary gap-1"
            >
              <.icon name="lucide-refresh-cw" class="w-3.5 h-3.5" />
              {gettext("Restart Service")}
            </button>
            <span :if={@reloading} class="loading loading-spinner loading-sm text-primary" />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign(:reloading, assigns[:service] && assigns.service.status == "reloading")
      |> assign_new(:capture_mode, fn -> false end)

    {:ok, socket}
  end

  defp status_badge_class("running"), do: "badge-success"
  defp status_badge_class("reloading"), do: "badge-info"
  defp status_badge_class("suspended"), do: "badge-warning"
  defp status_badge_class(_), do: "badge-error"
end
