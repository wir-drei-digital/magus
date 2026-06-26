defmodule MagusWeb.Workbench.Resources.Companions.PdfCompanion do
  @moduledoc """
  LiveView wrapper around the existing `PdfPaneComponent`. Mounted via
  `live_render` from `TabContainer` when a tab's companion is a PDF.

  Receives in session:
    - `"file_id"` — UUID of the file
    - `"filename"` — display name of the file
    - `"url"` — URL of the PDF (resolved by the opener via Storage.get_url)
    - `"conversation_id"` — parent conversation UUID
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id (for broadcasting :close_companion back)

  Owns:
    - The pdf data assembly
    - Rendering the PdfPaneComponent
  """
  use MagusWeb, :live_view

  alias MagusWeb.ChatLive.Components.Pdf.PdfPaneComponent
  alias MagusWeb.Workbench.Signals

  @impl true
  def mount(_params, session, socket) do
    file_id = session["file_id"]
    filename = session["filename"]
    url = session["url"]
    conversation_id = session["conversation_id"]
    tab_id = session["tab_id"]

    pdf_data = %{
      file: %{id: file_id, name: filename},
      url: url
    }

    {:ok,
     socket
     |> assign(:pdf, pdf_data)
     |> assign(:conversation_id, conversation_id)
     |> assign(:tab_id, tab_id)
     |> assign(:page_count, nil)
     |> assign(:zoom_percent, 100)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-pdf-companion
      data-file-id={@pdf.file.id}
      class="h-full flex flex-col"
    >
      <.live_component
        module={PdfPaneComponent}
        id={"pdf-companion-#{@pdf.file.id}"}
        pdf={@pdf}
        page_count={@page_count}
        zoom_percent={@zoom_percent}
      />
    </div>
    """
  end

  @impl true
  def handle_event("close_pane", _params, socket) do
    Signals.broadcast_close_companion(socket.assigns.tab_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_unhandled, socket), do: {:noreply, socket}
end
