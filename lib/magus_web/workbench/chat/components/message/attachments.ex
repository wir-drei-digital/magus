defmodule MagusWeb.ChatLive.Components.Message.Attachments do
  @moduledoc """
  Shared attachment display components for the message stream.

  Contains reusable function components for displaying images, videos, and file attachments.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents

  @doc """
  Renders user-uploaded file and image attachments.
  """
  attr :files, :list, required: true
  attr :images, :list, required: true
  attr :alignment, :string, default: "chat-start"

  def user_attachments(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap gap-2 mt-2",
      @alignment == "chat-end" && "justify-end"
    ]}>
      <%!-- File attachments --%>
      <%= for file <- @files do %>
        <%= if file["url"] do %>
          <%!-- Stored file with URL - make it a download link --%>
          <div class="flex items-center gap-1">
            <a
              href={file["url"]}
              target="_blank"
              class="flex items-center gap-2 px-3 py-2 rounded-lg bg-base-200 border border-base-300 max-w-xs hover:bg-base-300 transition-colors"
            >
              <.icon
                name={file_type_icon(file["type"])}
                class="w-5 h-5 text-base-content/70 shrink-0"
              />
              <div class="flex flex-col min-w-0">
                <span class="text-sm font-medium truncate">{file["name"]}</span>
                <span class="text-xs text-base-content/50">{format_file_size(file["size"])}</span>
              </div>
            </a>
            <button
              :if={is_pdf?(file["type"])}
              phx-click="open_pdf_pane"
              phx-value-file-id={file["id"]}
              phx-value-url={file["url"]}
              phx-value-name={file["name"]}
              class="btn btn-ghost btn-xs text-primary"
              title={gettext("View in PDF viewer")}
            >
              <.icon name="lucide-eye" class="w-3.5 h-3.5" />
            </button>
            <button
              :if={is_xlsx?(file["type"], file["name"])}
              phx-click="open_spreadsheet_pane"
              phx-value-file-id={file["id"]}
              phx-value-name={file["name"]}
              class="btn btn-ghost btn-xs text-primary"
              title={gettext("Open in spreadsheet editor")}
            >
              <.icon name="lucide-table-2" class="w-3.5 h-3.5" />
            </button>
          </div>
        <% else %>
          <%!-- Inline file without URL --%>
          <div class="flex items-center gap-2 px-3 py-2 rounded-lg bg-base-200 border border-base-300 max-w-xs">
            <.icon name={file_type_icon(file["type"])} class="w-5 h-5 text-base-content/70 shrink-0" />
            <div class="flex flex-col min-w-0">
              <span class="text-sm font-medium truncate">{file["name"]}</span>
              <span class="text-xs text-base-content/50">{format_file_size(file["size"])}</span>
            </div>
          </div>
        <% end %>
      <% end %>

      <%!-- Image attachments as thumbnails --%>
      <div
        :for={image <- @images}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-base-200 border border-base-300 max-w-xs"
      >
        <.icon name="lucide-image" class="w-5 h-5 text-base-content/70 shrink-0" />
        <div class="flex flex-col min-w-0">
          <span class="text-sm font-medium truncate">{image["name"]}</span>
          <span class="text-xs text-base-content/50">{format_file_size(image["size"])}</span>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders generated image attachments with download button.
  """
  attr :attachments, :list, required: true

  def image_attachments(assigns) do
    images = Enum.filter(assigns.attachments || [], fn a -> a["type"] == "image" end)
    assigns = assign(assigns, :images, images)

    ~H"""
    <div :if={@images != []} class="mt-3 grid gap-2 not-prose">
      <div :for={image <- @images} class="relative group inline-block">
        <img
          src={get_image_src(image)}
          class="rounded-lg max-w-md shadow-md"
          alt={gettext("Generated image")}
        />
        <a
          href={get_image_src(image)}
          download
          class="absolute top-2 right-2 btn btn-circle btn-sm btn-ghost bg-base-100/80 opacity-0 group-hover:opacity-100 transition-opacity"
          title={gettext("Download image")}
        >
          <.icon name="lucide-download" class="w-4 h-4" />
        </a>
      </div>
    </div>
    """
  end

  @doc """
  Renders generated video attachments with download button.
  """
  attr :attachments, :list, required: true

  def video_attachments(assigns) do
    videos = Enum.filter(assigns.attachments, fn a -> a["type"] == "video" end)
    assigns = assign(assigns, :videos, videos)

    ~H"""
    <div :if={@videos != []} class="mt-3 grid gap-2 not-prose">
      <div :for={video <- @videos} class="relative group">
        <video
          controls
          class="rounded-lg max-w-lg shadow-md"
          preload="metadata"
        >
          <source src={video["url"]} type="video/mp4" />
          {gettext("Your browser does not support the video tag.")}
        </video>
        <a
          href={video["url"]}
          download
          class="absolute top-2 right-2 btn btn-circle btn-sm btn-ghost bg-base-100/80 opacity-0 group-hover:opacity-100 transition-opacity"
          title={gettext("Download video")}
        >
          <.icon name="lucide-download" class="w-4 h-4" />
        </a>
        <span
          :if={video["duration"]}
          class="absolute bottom-2 right-2 badge badge-neutral badge-sm"
        >
          {format_duration(video["duration"])}
        </span>
      </div>
    </div>
    """
  end

  # Helper functions

  defp is_pdf?(mime_type) when is_binary(mime_type), do: String.contains?(mime_type, "pdf")
  defp is_pdf?(_), do: false

  defp is_xlsx?(mime_type, name) do
    cond do
      is_binary(mime_type) and String.contains?(mime_type, "spreadsheetml") -> true
      is_binary(name) and String.ends_with?(String.downcase(name), ".xlsx") -> true
      true -> false
    end
  end

  defp file_type_icon(mime_type) when is_binary(mime_type) do
    cond do
      String.contains?(mime_type, "pdf") -> "lucide-file"
      String.starts_with?(mime_type, "text/") -> "lucide-file-text"
      String.contains?(mime_type, "markdown") -> "lucide-file-text"
      true -> "lucide-paperclip"
    end
  end

  defp file_type_icon(_), do: "lucide-paperclip"

  defp format_file_size(nil), do: ""

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_file_size(_), do: ""

  defp get_image_src(image) do
    image["url"] || image["data_url"]
  end

  defp format_duration(nil), do: ""

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_duration(_), do: ""
end
