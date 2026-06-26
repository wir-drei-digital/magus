defmodule Magus.Chat.MessageQueueTest do
  # NOTE: Brief specified `Magus.DataCase` + `Magus.AccountsFixtures.user_fixture()`,
  # but this suite uses `Magus.ResourceCase` + `generate(user())` (the real helpers).
  # Behavior asserted is identical to the brief.
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "q"}, actor: user)
    %{user: user, conversation: conversation}
  end

  # NOTE: The brief's test snippet called `enqueue_message(params, conversation_id, ...)`.
  # Ash code interfaces with `args: [:conversation_id]` take named args positionally
  # FIRST, then the params map -- i.e. `enqueue_message(conversation_id, params, opts)`,
  # the same convention as the brief's own `list_queued_messages(conversation.id, ...)`.
  # Calls below use the correct ordering; the asserted behavior is unchanged.
  test "enqueue_message creates a :queued user message without dispatching",
       %{user: user, conversation: conversation} do
    {:ok, msg} =
      Chat.enqueue_message(conversation.id, %{text: "later"}, actor: user)

    assert msg.status == :queued
    assert msg.role == :user
  end

  test "queued_for_conversation returns queued messages oldest-first",
       %{user: user, conversation: conversation} do
    {:ok, a} = Chat.enqueue_message(conversation.id, %{text: "a"}, actor: user)
    {:ok, b} = Chat.enqueue_message(conversation.id, %{text: "b"}, actor: user)

    ids = Chat.list_queued_messages!(conversation.id, actor: user) |> Enum.map(& &1.id)
    assert ids == [a.id, b.id]
  end

  test "flush_queued promotes :queued -> :complete",
       %{user: user, conversation: conversation} do
    {:ok, msg} = Chat.enqueue_message(conversation.id, %{text: "x"}, actor: user)
    {:ok, flushed} = Chat.flush_queued_message(msg, actor: user)
    assert flushed.status == :complete
  end

  # A queued message is created the moment the user types it mid-turn, so its
  # `inserted_at` is the *enqueue* time -- earlier than the agent reply that was
  # still streaming when they typed it. Every transcript orders by `inserted_at`,
  # so without re-stamping on delivery the flushed follow-up sorts *above* that
  # reply. Flushing must stamp the *received* time so it orders after anything
  # that arrived while it was queued.
  test "flush_queued stamps delivery time so a flushed message orders after later-queued ones",
       %{user: user, conversation: conversation} do
    {:ok, follow_up} = Chat.enqueue_message(conversation.id, %{text: "follow-up"}, actor: user)
    # Distinct, monotonic timestamps (usec clock) for a deterministic comparison.
    Process.sleep(2)
    # Anything that landed after the follow-up was queued (here a second message;
    # in the real bug, the agent reply that was mid-stream).
    {:ok, later} = Chat.enqueue_message(conversation.id, %{text: "later"}, actor: user)
    Process.sleep(2)

    {:ok, flushed} = Chat.flush_queued_message(follow_up, actor: user)

    assert DateTime.compare(flushed.inserted_at, later.inserted_at) == :gt
  end

  test "flush_queued is rejected when already non-queued",
       %{user: user, conversation: conversation} do
    {:ok, msg} = Chat.enqueue_message(conversation.id, %{text: "x"}, actor: user)
    {:ok, flushed} = Chat.flush_queued_message(msg, actor: user)
    assert {:error, _} = Chat.flush_queued_message(flushed, actor: user)
  end

  test "remove_queued deletes the row", %{user: user, conversation: conversation} do
    {:ok, msg} = Chat.enqueue_message(conversation.id, %{text: "x"}, actor: user)
    assert :ok = Chat.remove_queued_message(msg, actor: user)
    assert Chat.list_queued_messages!(conversation.id, actor: user) == []
  end

  test "remove_queued is rejected for a non-queued (flushed/:complete) message",
       %{user: user, conversation: conversation} do
    {:ok, msg} = Chat.enqueue_message(conversation.id, %{text: "x"}, actor: user)
    {:ok, flushed} = Chat.flush_queued_message(msg, actor: user)
    assert flushed.status == :complete

    # Status guard prevents repurposing remove_queued to delete delivered messages.
    assert {:error, _} = Chat.remove_queued_message(flushed, actor: user)
  end
end
