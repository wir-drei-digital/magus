defmodule MagusWeb.ChatLive.Components.Brain.Blocks.FileBlockComponent do
  @moduledoc """
  Renders a file attachment block. Three render paths:
  - Image (type :image or mime image/*) -> inline thumbnail (lazy-loaded, max-h: 240px)
  - File missing -> "no longer available" placeholder card
  - Otherwise -> compact card with type icon, filename, size, mime, caption

  Files in :pending or :processing status get a dedicated processing card so
  users see why the preview is unavailable.
  """

  use MagusWeb, :html

  attr :block, :map, required: true
  attr :file, :map, default: nil

  def file_block(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@file) -> %>
        <.placeholder_card caption={Map.get(@block.content || %{}, "caption", "")} />
      <% image?(@file) -> %>
        <.image_block file={@file} caption={Map.get(@block.content || %{}, "caption", "")} />
      <% @file.status in [:pending, :processing] -> %>
        <.processing_card file={@file} caption={Map.get(@block.content || %{}, "caption", "")} />
      <% true -> %>
        <.compact_card file={@file} caption={Map.get(@block.content || %{}, "caption", "")} />
    <% end %>
    """
  end

  attr :caption, :string, required: true

  defp placeholder_card(assigns) do
    ~H"""
    <div class="bg-base-200/50 border border-warning/30 rounded-lg p-3 my-2 flex items-center gap-3 not-prose">
      <div class="bg-warning/10 rounded-md w-9 h-9 flex items-center justify-center text-lg">
        ⚠️
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium text-base-content truncate">
          {gettext("File no longer available")}
        </div>
        <div :if={@caption != ""} class="text-xs text-base-content/40 truncate">{@caption}</div>
      </div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :caption, :string, required: true

  defp image_block(assigns) do
    ~H"""
    <div class="my-2 not-prose relative group" data-file-id={@file.id}>
      <img
        src={image_url(@file)}
        alt={@file.name}
        loading="lazy"
        class="rounded max-h-[240px] w-auto"
      />
      <div :if={@caption != ""} class="text-xs text-base-content/60 mt-1">{@caption}</div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :caption, :string, required: true

  defp processing_card(assigns) do
    ~H"""
    <div class="bg-base-200/50 border border-base-300/50 rounded-lg p-3 my-2 flex items-center gap-3 not-prose">
      <div class="bg-base-300/50 rounded-md w-9 h-9 flex items-center justify-center text-lg">
        ⏳
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium text-base-content truncate">{@file.name}</div>
        <div class="text-xs text-base-content/40">{gettext("Processing")}…</div>
      </div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :caption, :string, required: true

  defp compact_card(assigns) do
    ~H"""
    <div
      class="bg-base-200/50 border border-base-300/50 rounded-lg p-3 my-2 flex items-center gap-3 not-prose cursor-pointer hover:bg-base-200/70"
      data-file-id={@file.id}
    >
      <div class="bg-base-300/50 rounded-md w-9 h-9 flex items-center justify-center text-lg">
        {file_icon(@file)}
      </div>
      <div class="flex-1 min-w-0">
        <div class="text-sm font-medium text-base-content truncate">{@file.name}</div>
        <div class="text-xs text-base-content/40">
          {@file.mime_type || ""} · {format_bytes(@file.file_size)}
        </div>
        <div :if={@caption != ""} class="text-xs text-base-content/60 truncate">{@caption}</div>
      </div>
      <div class="text-base-content/40 text-xs">open ↗</div>
    </div>
    """
  end

  defp image?(%{type: :image}), do: true
  defp image?(%{mime_type: "image/" <> _}), do: true
  defp image?(_), do: false

  defp image_url(%{file_path: nil}), do: ""

  defp image_url(%{file_path: path}) when is_binary(path) do
    case Magus.Files.Storage.get_url(path) do
      {:ok, url} -> url
      _ -> ""
    end
  end

  defp image_url(_), do: ""

  defp file_icon(%{type: :image}), do: "🖼"
  defp file_icon(%{type: :video}), do: "🎬"
  defp file_icon(%{type: :text}), do: "📝"
  defp file_icon(%{type: :email}), do: "✉️"
  defp file_icon(%{mime_type: "application/pdf"}), do: "📄"
  defp file_icon(%{type: :document}), do: "📃"
  defp file_icon(_), do: "📎"

  defp format_bytes(nil), do: ""
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / (1024 * 1024), 1)} MB"
end
