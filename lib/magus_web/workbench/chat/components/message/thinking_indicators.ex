defmodule MagusWeb.ChatLive.Components.Message.ThinkingIndicators do
  @moduledoc """
  Thinking and reasoning indicator components for the message stream.

  Contains components for displaying AI reasoning states during response generation.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents

  @doc """
  Renders the streaming thinking indicator shown while the model is reasoning.
  """
  attr :streaming_thinking, :string, required: true
  attr :is_multiplayer, :boolean, default: false

  def streaming_thinking_indicator(assigns) do
    # Create a brief preview of the reasoning (first ~60 chars)
    preview =
      assigns.streaming_thinking |> String.slice(0, 60) |> String.replace("\n", " ")

    preview =
      if String.length(assigns.streaming_thinking) > 60, do: preview <> "...", else: preview

    assigns = assign(assigns, :preview, preview)

    ~H"""
    <details class="group ml-2 pt-2" open>
      <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
        <.icon name="lucide-brain" class="w-4 h-4 text-info animate-pulse shrink-0" />
        <span>{gettext("Reasoning...")}</span>
        <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{@preview}</pre>
      </summary>
      <div class="mt-2 ml-2 border-l border-base-300 pl-3">
        <div
          id="streaming-thinking-content"
          class="prose prose-sm dark:prose-invert max-w-none max-h-64 overflow-y-auto text-xs"
          phx-hook="AutoScrollContent"
        >
          {to_markdown(@streaming_thinking)}
        </div>
      </div>
    </details>
    """
  end

  @doc """
  Renders a collapsible reasoning display for completed messages.
  """
  attr :reasoning_summary, :list, required: true

  def reasoning_display(assigns) do
    reasoning_text = Enum.join(assigns.reasoning_summary, "\n\n")
    # Create a brief preview of the reasoning (first ~50 chars)
    preview = reasoning_text |> String.slice(0, 60) |> String.replace("\n", " ")
    preview = if String.length(reasoning_text) > 60, do: preview <> "...", else: preview

    assigns =
      assigns
      |> assign(:reasoning_text, reasoning_text)
      |> assign(:preview, preview)

    ~H"""
    <details :if={@reasoning_summary != []} class="group ml-2">
      <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
        <.icon
          name="lucide-brain"
          class="w-4 h-4 text-base-content/50 group-hover:text-warning shrink-0"
        />
        <span>{gettext("Reasoning")}</span>
        <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{@preview}</pre>
      </summary>
      <div class="mt-2 ml-2 border-l border-base-300 pl-3">
        <div class="prose prose-sm dark:prose-invert max-w-none max-h-64 overflow-y-auto text-xs">
          {to_markdown(@reasoning_text)}
        </div>
      </div>
    </details>
    """
  end

  # Simple markdown helper for thinking content
  defp to_markdown(text) do
    MDEx.to_html(text,
      extension: [
        strikethrough: true,
        tagfilter: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true,
        shortcodes: true
      ],
      parse: [
        smart: true,
        relaxed_tasklist_matching: true,
        relaxed_autolinks: true
      ],
      render: [
        github_pre_lang: true,
        unsafe: false
      ],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> case do
      {:ok, html} -> Phoenix.HTML.raw(html)
      {:error, _} -> text
    end
  end
end
