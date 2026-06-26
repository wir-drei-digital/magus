defmodule MagusWeb.ChatLive.Components.Brain.Blocks.ImageBlockComponent do
  @moduledoc """
  Renders an image block as a card with a placeholder icon
  and optional caption text.
  """

  use MagusWeb, :html

  attr :block, :map, required: true

  def image_block(assigns) do
    ~H"""
    <div class="my-2 not-prose">
      <div
        :if={@block.content["file_id"]}
        class="rounded-lg overflow-hidden border border-base-300/50"
      >
        <div class="bg-base-200/50 p-8 flex items-center justify-center text-base-content/30">
          <.icon name="lucide-image" class="w-8 h-8" />
        </div>
      </div>
      <p :if={@block.content["caption"]} class="text-xs text-base-content/60 mt-1 px-1">
        {@block.content["caption"]}
      </p>
    </div>
    """
  end
end
