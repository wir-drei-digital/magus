defmodule Magus.Skills.LoaderTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Loader

  setup do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "L"}, actor: user)
    %{user: user, conversation: conversation}
  end

  test "loads a builtin skill and persists context onto the conversation",
       %{user: user, conversation: conversation} do
    # brainstorming is a built-in registry skill
    ctx = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, result} = Loader.load("builtin:brainstorming", ctx, [])

    assert result.skill == "brainstorming"
    assert result.content =~ "" and byte_size(result.content) > 0

    {:ok, reloaded} = Magus.Chat.get_conversation(conversation.id, authorize?: false)
    assert reloaded.skill_context =~ result.content
  end

  test "returns not-found for an unknown ref", %{user: user, conversation: conversation} do
    ctx = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, result} = Loader.load("builtin:does-not-exist", ctx, [])
    assert result.error =~ "not found"
    assert is_list(result.available_skills)
  end
end
