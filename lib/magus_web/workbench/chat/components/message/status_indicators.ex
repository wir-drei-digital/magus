defmodule MagusWeb.ChatLive.Components.Message.StatusIndicators do
  @moduledoc """
  Shared status indicator components for AI response state.

  Used by both the main message stream and the thread pane to show
  thinking/processing indicators during agent responses.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  @doc """
  Renders the AI thinking/processing status indicator.

  Shows a spinner with contextual status text when the AI is processing.
  Accepts a unique `id` to avoid DOM conflicts when multiple instances exist.

  ## Assigns
    * `waiting` - whether the AI is currently processing
    * `streaming` - whether the AI is currently streaming text
    * `thinking_status` - atom describing the current phase (:thinking, :running_tools, etc.)
    * `id` - unique DOM ID prefix (default: "thinking-indicator")
  """
  attr :waiting, :boolean, default: false
  attr :streaming, :boolean, default: false
  attr :thinking_status, :atom, default: :thinking
  attr :id, :string, default: "thinking-indicator"

  def response_status_indicator(assigns) do
    show = assigns.waiting and assigns.thinking_status != :running_tools and not assigns.streaming
    status_text = thinking_status_text(assigns.thinking_status)
    assigns = assign(assigns, show: show, status_text: status_text)

    ~H"""
    <div :if={@show} class="pt-2 ml-2" id={@id}>
      <div class="flex items-center gap-2 py-2 px-3 text-sm text-base-content/60">
        <span class="thinking-spinner">◬</span>
        <span>{@status_text}...</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders the compaction-in-progress indicator.

  Shown while the conversation's context window is `:pending` or `:running`,
  taking precedence over the thinking indicator (which the stream suppresses
  while compacting) to explain why the composer is locked.

  ## Assigns
    * `compacting` - whether a compaction is currently in flight
  """
  attr :compacting, :boolean, default: false

  def compacting_indicator(assigns) do
    ~H"""
    <div :if={@compacting} class="pt-2 ml-2" data-role="agent-compacting">
      <div class="flex items-center gap-2 py-2 px-3 text-sm text-base-content/60">
        <span class="loading loading-spinner loading-xs"></span>
        <span>{gettext("Compacting context")}...</span>
      </div>
    </div>
    """
  end

  defp thinking_status_text(:thinking), do: gettext("Thinking")
  defp thinking_status_text(:reasoning), do: gettext("Reasoning")
  defp thinking_status_text(:running_tools), do: gettext("Running tools")
  defp thinking_status_text(:generating_response), do: gettext("Generating response")
  defp thinking_status_text(:generating_image), do: gettext("Generating image")
  defp thinking_status_text(:generating_video), do: gettext("Generating video")
  defp thinking_status_text(_), do: gettext("Thinking")
end
