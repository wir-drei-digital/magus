defmodule MagusWeb.ChatLive.Components.Pdf.PdfPaneComponent do
  @moduledoc """
  Live component for rendering an interactive PDF viewer in the side pane.

  Uses PDF.js via a LiveView hook to render the PDF. Users can draw a rectangle
  over any region of the PDF and click "Ask" to send a screenshot of that region
  to the chat as visual context.

  The component is presentational — selection events are forwarded to the parent
  LiveView via `notify_parent/1`.
  """

  use MagusWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full border-l border-base-300 bg-base-100 relative">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 border-b border-base-300 bg-base-100/80 backdrop-blur-sm relative z-10">
        <div class="flex items-center gap-2 min-w-0 pr-2">
          <.icon name="lucide-file" class="w-4 h-4 text-primary flex-shrink-0" />
          <h3 class="font-medium text-sm truncate">{@pdf.file.name}</h3>
          <span
            :if={@page_count}
            class="text-xs text-base-content/50 shrink-0"
          >
            {ngettext("%{count} page", "%{count} pages", @page_count)}
          </span>
        </div>
        <div class="flex items-center gap-1">
          <%!-- Zoom controls --%>
          <div class="join join-horizontal">
            <button
              type="button"
              phx-click="pdf:zoom_out"
              phx-target={@myself}
              class="btn btn-ghost btn-xs join-item"
              title={gettext("Zoom out")}
            >
              <.icon name="lucide-minus" class="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs join-item font-mono text-xs min-w-[3.5rem]"
              phx-click="pdf:zoom_reset"
              phx-target={@myself}
              title={gettext("Reset zoom")}
            >
              {@zoom_percent}%
            </button>
            <button
              type="button"
              phx-click="pdf:zoom_in"
              phx-target={@myself}
              class="btn btn-ghost btn-xs join-item"
              title={gettext("Zoom in")}
            >
              <.icon name="lucide-plus" class="w-3.5 h-3.5" />
            </button>
          </div>
          <div class="divider divider-horizontal mx-0 h-5 self-center"></div>
          <a
            href={@pdf.url}
            download
            class="btn btn-ghost btn-xs gap-1"
            title={gettext("Download PDF")}
          >
            <.icon name="lucide-download" class="w-3.5 h-3.5" />
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

      <%!-- PDF Viewer Container --%>
      <div
        id="pdf-viewer-container"
        class="flex-1 overflow-auto"
        phx-hook="PdfViewer"
        phx-update="ignore"
        data-pdf-url={@pdf.url}
      >
        <div class="pdf-viewer-pages flex flex-col items-center gap-4 p-4">
          <%!-- Pages are rendered by the JS hook --%>
        </div>
      </div>
    </div>
    """
  end

  @zoom_steps [25, 50, 75, 100, 125, 150, 200, 300]
  @default_zoom 100

  @impl true
  def update(assigns, socket) do
    pdf_changed? =
      Map.has_key?(assigns, :pdf) and
        Map.has_key?(socket.assigns, :pdf) and
        assigns.pdf.file.id != socket.assigns.pdf.file.id

    socket =
      socket
      |> assign(assigns)
      |> then(fn s ->
        if pdf_changed?,
          do:
            s
            |> assign(page_count: nil, zoom_percent: @default_zoom)
            |> push_event("pdf_viewer:load", %{url: assigns.pdf.url}),
          else: s
      end)
      |> assign_new(:page_count, fn -> nil end)
      |> assign_new(:zoom_percent, fn -> @default_zoom end)

    {:ok, socket}
  end

  @impl true
  def handle_event("pdf:page_count", %{"count" => count}, socket) do
    {:noreply, assign(socket, :page_count, count)}
  end

  def handle_event("pdf:zoom_in", _, socket) do
    current = socket.assigns.zoom_percent
    new_zoom = Enum.find(@zoom_steps, current, &(&1 > current))
    {:noreply, push_zoom(socket, new_zoom)}
  end

  def handle_event("pdf:zoom_out", _, socket) do
    current = socket.assigns.zoom_percent
    new_zoom = @zoom_steps |> Enum.reverse() |> Enum.find(current, &(&1 < current))
    {:noreply, push_zoom(socket, new_zoom)}
  end

  def handle_event("pdf:zoom_reset", _, socket) do
    {:noreply, push_zoom(socket, @default_zoom)}
  end

  defp push_zoom(socket, zoom) do
    socket
    |> assign(:zoom_percent, zoom)
    |> push_event("pdf_viewer:zoom", %{scale: zoom / 100})
  end
end
