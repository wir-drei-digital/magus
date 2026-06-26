defmodule MagusWeb.ChatLive.Components.Brain.Blocks.SourceBlockComponent do
  @moduledoc """
  Renders a source reference block as a card with icon, title, host URL,
  description, ingestion status badge, and external link.
  """

  use MagusWeb, :html

  attr :block, :map, required: true

  def source_block(assigns) do
    ~H"""
    <div class="bg-base-200/50 border border-base-300/50 rounded-lg p-3 my-2 not-prose">
      <div class="flex items-center gap-2 mb-1">
        <span class="text-sm">{source_icon(@block.content["source_type"])}</span>
        <span class="text-sm font-medium text-base-content truncate">
          {@block.content["text"] || @block.content["title"] || "Untitled source"}
        </span>
        <span
          :if={@block.content["url"]}
          class="text-xs text-base-content/40 ml-auto truncate max-w-[120px]"
        >
          {extract_host(@block.content["url"])}
        </span>
      </div>
      <p :if={@block.content["description"]} class="text-xs text-base-content/60 mt-1">
        {@block.content["description"]}
      </p>
      <div class="flex gap-2 mt-2">
        <span
          :if={@block.metadata["ingested"] == true}
          class="text-xs bg-base-300/50 px-2 py-0.5 rounded text-primary"
        >
          {gettext("content extracted")}
        </span>
        <span
          :if={@block.metadata["ingestion_error"]}
          class="text-xs bg-error/10 px-2 py-0.5 rounded text-error"
        >
          {gettext("extraction failed")}
        </span>
        <a
          :if={@block.content["url"]}
          href={@block.content["url"]}
          target="_blank"
          rel="noopener"
          class="text-xs text-base-content/40 hover:text-primary"
        >
          {gettext("open")} →
        </a>
      </div>
    </div>
    """
  end

  defp source_icon("video"), do: "🎥"
  defp source_icon("pdf"), do: "📄"
  defp source_icon("paper"), do: "📑"
  defp source_icon(_), do: "🔗"

  defp extract_host(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  defp extract_host(_), do: ""
end
