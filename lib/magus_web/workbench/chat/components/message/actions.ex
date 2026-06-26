defmodule MagusWeb.ChatLive.Components.Message.Actions do
  @moduledoc """
  Components for message action buttons and citations display.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents
  import MagusWeb.ChatLive.Components.Message.BrainActions
  alias Phoenix.LiveView.JS

  @doc """
  Renders inline action buttons for a message.
  Includes toggle disabled, retry, copy, and create prompt buttons.
  """
  attr(:item, :map, required: true)
  attr(:is_disabled, :boolean, default: false)
  attr(:target, :any, default: nil)
  attr(:is_thread_context, :boolean, default: false)
  attr(:brain_pane_page_id, :any, default: nil)

  def message_actions_inline(assigns) do
    ~H"""
    <div class="flex gap-0 opacity-0 group-hover:opacity-100 transition-opacity">
      <.brain_actions message={@item} brain_pane_page_id={@brain_pane_page_id} />
      <%!-- Disable/Enable toggle --%>
      <button
        type="button"
        class={["btn btn-ghost btn-xs h-5 min-h-5 px-1", @is_disabled && "text-warning"]}
        title={
          if @is_disabled,
            do: gettext("Include message in context"),
            else: gettext("Hide message from context")
        }
        phx-click="toggle_message_disabled"
        phx-value-message-id={@item.id}
        phx-target={@target}
      >
        <.icon name={if @is_disabled, do: "lucide-eye", else: "lucide-eye-off"} class="w-3 h-3" />
      </button>

      <%!-- Retry button (only for user messages) --%>
      <button
        :if={@item.source == :user}
        type="button"
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1"
        title={gettext("Retry message")}
        phx-click="retry_message"
        phx-value-message-id={@item.id}
        phx-target={@target}
      >
        <.icon name="lucide-refresh-cw" class="w-3 h-3" />
      </button>

      <%!-- Copy button --%>
      <button
        type="button"
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1"
        title={gettext("Copy to clipboard")}
        phx-click={JS.dispatch("phx:copy", to: "#message-text-#{@item.id}")}
      >
        <.icon name="lucide-clipboard-copy" class="w-3 h-3" />
      </button>

      <%!-- Create prompt from message button --%>
      <button
        type="button"
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1"
        title={gettext("Create prompt from message")}
        phx-click="create_prompt_from_message"
        phx-value-message-id={@item.id}
        phx-target={@target}
      >
        <.icon name="lucide-sparkles" class="w-3 h-3" />
      </button>

      <%!-- Start thread button (only on messages without threads, not in thread context) --%>
      <button
        :if={!@is_thread_context && Map.get(@item, :thread_count, 0) == 0}
        type="button"
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1"
        title={gettext("Reply in thread")}
        phx-click="start_thread"
        phx-value-message-id={@item.id}
      >
        {gettext("New thread")}
        <.icon name="lucide-arrow-right" class="w-3 h-3" />
      </button>

      <%!-- Drag handle for brain pane (rightmost) --%>
      <span
        :if={@brain_pane_page_id}
        id={"drag-handle-#{@item.id}"}
        draggable="true"
        phx-hook="DraggableMessage"
        data-message-id={@item.id}
        data-conversation-id={@item.conversation_id}
        data-text={String.slice(@item.text || "", 0, 500)}
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1 cursor-grab active:cursor-grabbing select-none"
        title={gettext("Drag to brain")}
        aria-label={gettext("Drag message to brain")}
      >
        <.icon name="lucide-grip-vertical" class="w-3 h-3" />
      </span>
    </div>
    """
  end

  @doc """
  Renders a list of citation sources for a message.
  """
  attr(:citations, :list, required: true)

  def citations_display(assigns) do
    ~H"""
    <div :if={@citations != []} class="mt-3 pt-3 border-t border-base-300 not-prose">
      <div class="text-xs text-base-content/60 mb-2">{gettext("Sources:")}</div>
      <ul class="text-sm space-y-1">
        <li :for={citation <- @citations} class="truncate">
          <% url = citation["url"] || citation[:url] %>
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            class="link link-primary hover:link-hover"
          >
            {url}
          </a>
        </li>
      </ul>
    </div>
    """
  end
end
