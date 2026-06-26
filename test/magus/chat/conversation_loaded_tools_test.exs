defmodule Magus.Chat.ConversationLoadedToolsTest do
  use Magus.ResourceCase, async: true

  import Magus.Generators

  alias Magus.Chat

  test "set_conversation_loaded_tools persists tool names on the conversation" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    {:ok, updated} =
      Chat.set_conversation_loaded_tools(
        conversation,
        %{loaded_tools: ["roll_dice", "generate_image"]},
        authorize?: false
      )

    assert updated.loaded_tools == ["roll_dice", "generate_image"]

    reloaded = Chat.get_conversation!(updated.id, authorize?: false)
    assert reloaded.loaded_tools == ["roll_dice", "generate_image"]
  end

  test "loaded_tools defaults to nil on a new conversation" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    assert conversation.loaded_tools in [nil, []]
  end
end
