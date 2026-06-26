defmodule MagusWeb.ChatLive.Components.Brain.Blocks.MessageBlockComponent do
  @moduledoc """
  Renders a message reference block as a card with a left accent border,
  "from conversation" badge, preview text, and a navigation link.
  """

  use MagusWeb, :html

  attr :block, :map, required: true

  def message_block(assigns) do
    ~H"""
    <div class="bg-base-200/50 border-l-[3px] border-l-primary rounded-r-lg p-3 my-2 not-prose">
      <div class="flex items-center gap-2 mb-1">
        <span class="text-xs bg-primary text-primary-content px-1.5 py-0.5 rounded font-medium">
          {gettext("from conversation")}
        </span>
      </div>
      <p class="text-sm text-base-content leading-relaxed">
        {@block.content["preview_text"] || "..."}
      </p>
      <button
        :if={@block.content["conversation_id"]}
        phx-click="navigate_to_conversation"
        phx-value-conversation-id={@block.content["conversation_id"]}
        class="text-xs text-primary mt-2 hover:underline"
      >
        {gettext("Open conversation")} →
      </button>
    </div>
    """
  end
end
