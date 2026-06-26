defmodule Magus.Agents.Tools.Search.LoadToolTest do
  use Magus.ResourceCase, async: true

  import Magus.Generators

  alias Magus.Agents.Tools.Search.LoadTool
  alias Magus.Agents.Tools.DiceRoll
  alias Magus.Chat

  test "loads known tools, persists them, and attaches __new_tools__" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    {:ok, result} =
      LoadTool.run(%{names: ["roll_dice"]}, %{conversation_id: conversation.id})

    assert result.loaded == ["roll_dice"]
    assert result.unknown == []
    assert DiceRoll in result.__new_tools__

    reloaded = Chat.get_conversation!(conversation.id, authorize?: false)
    assert reloaded.loaded_tools == ["roll_dice"]
  end

  test "reports unknown names and does not crash" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    {:ok, result} =
      LoadTool.run(%{names: ["no_such_tool"]}, %{conversation_id: conversation.id})

    assert result.loaded == []
    assert result.unknown == ["no_such_tool"]
    refute Map.has_key?(result, :__new_tools__)
  end

  test "merges with already-loaded tools without duplicates" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    {:ok, _} = LoadTool.run(%{names: ["roll_dice"]}, %{conversation_id: conversation.id})

    {:ok, _} =
      LoadTool.run(%{names: ["roll_dice", "list_models"]}, %{conversation_id: conversation.id})

    reloaded = Chat.get_conversation!(conversation.id, authorize?: false)
    assert Enum.sort(reloaded.loaded_tools) == ["list_models", "roll_dice"]
  end
end
