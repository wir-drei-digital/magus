defmodule MagusWeb.Workbench.Chat.PendingChatActionTest do
  use ExUnit.Case, async: false

  alias MagusWeb.Workbench.Chat.PendingChatAction

  setup do
    PendingChatAction.init()
    user_id = Ecto.UUID.generate()
    on_exit(fn -> PendingChatAction.take(user_id) end)
    %{user_id: user_id}
  end

  test "init/0 is idempotent", _ do
    assert :ok = PendingChatAction.init()
    assert :ok = PendingChatAction.init()
  end

  test "put then take returns the action", %{user_id: user_id} do
    action = {:set_custom_agent, %{id: "agent-123"}}
    assert :ok = PendingChatAction.put(user_id, action)
    assert ^action = PendingChatAction.take(user_id)
  end

  test "take/1 consumes the action", %{user_id: user_id} do
    PendingChatAction.put(user_id, {:insert_text, "hello"})
    assert {:insert_text, "hello"} = PendingChatAction.take(user_id)
    assert nil == PendingChatAction.take(user_id)
  end

  test "take/1 returns nil when nothing is stored", %{user_id: user_id} do
    assert nil == PendingChatAction.take(user_id)
  end

  test "put/2 overwrites an existing action for the same user", %{user_id: user_id} do
    PendingChatAction.put(user_id, {:insert_text, "first"})
    PendingChatAction.put(user_id, {:insert_text, "second"})
    assert {:insert_text, "second"} = PendingChatAction.take(user_id)
  end

  test "actions are scoped per user", _ do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    PendingChatAction.put(a, {:insert_text, "for-a"})
    PendingChatAction.put(b, {:insert_text, "for-b"})

    assert {:insert_text, "for-a"} = PendingChatAction.take(a)
    assert {:insert_text, "for-b"} = PendingChatAction.take(b)
  end
end
