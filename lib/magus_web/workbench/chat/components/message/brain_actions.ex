defmodule MagusWeb.ChatLive.Components.Message.BrainActions do
  @moduledoc """
  Brain action buttons rendered on chat messages when a brain page is open.

  Provides "Add to brain" to save message content as a block, and
  "Add source" for citation URLs found in the message.
  """
  use MagusWeb, :html

  attr :message, :map, required: true
  attr :brain_pane_page_id, :any, default: nil

  def brain_actions(assigns) do
    citations = Map.get(assigns.message, :citations, []) || []

    assigns = assign(assigns, :citations, citations)

    ~H"""
    <div :if={@brain_pane_page_id} class="flex gap-1">
      <button
        type="button"
        phx-click="add_message_to_brain"
        phx-value-message-id={@message.id}
        phx-value-conversation-id={@message.conversation_id}
        phx-value-text={String.slice(@message.text || "", 0, 500)}
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1 gap-0.5"
        title={gettext("Add to brain")}
      >
        <.icon name="lucide-brain" class="w-3 h-3" />
      </button>

      <button
        :for={citation <- @citations}
        :if={citation["url"] || citation[:url]}
        type="button"
        phx-click="add_source_from_message"
        phx-value-url={citation["url"] || citation[:url]}
        phx-value-title={citation["title"] || citation[:title] || citation["url"] || citation[:url]}
        class="btn btn-ghost btn-xs h-5 min-h-5 px-1 gap-0.5"
        title={gettext("Add source to brain")}
      >
        <.icon name="lucide-link" class="w-3 h-3" />
      </button>
    </div>
    """
  end
end
