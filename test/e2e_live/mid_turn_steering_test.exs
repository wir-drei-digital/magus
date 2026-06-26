defmodule Magus.LiveE2E.MidTurnSteeringTest do
  @moduledoc """
  Live E2E for mid-turn steering auto-flush.

  Verifies that a `:queued` user message is automatically promoted and
  delivered (a second turn) once the in-flight turn completes, via the
  PersistencePlugin post-turn auto-flush -> Steering.flush_conversation path.

  Deterministic by construction: the steering message is enqueued BEFORE the
  first turn is triggered, so it is reliably waiting in the queue when turn 1
  completes and the auto-flush runs.

  Assertions are robust to nondeterministic LLM wording: they check QUEUE STATE
  and message role/status/count, never specific reply text.
  """
  use Magus.LiveE2ECase, async: false

  require Ash.Query

  @moduletag :e2e_live
  @moduletag :steering

  @queued_text "Now name three colors."
  @first_text "Reply with a one-word greeting."

  test "a queued message auto-flushes and is answered after the turn", %{
    user: user,
    model: model
  } do
    conversation = create_conversation(user, model)
    subscribe_to_agent(conversation.id)

    # Enqueue the steering message FIRST: :queued, no agent dispatch.
    {:ok, queued} =
      Chat.enqueue_message(conversation.id, %{text: @queued_text}, actor: user)

    assert queued.status == :queued

    # It is sitting in the queue, undelivered.
    assert [%{id: queued_id}] =
             Chat.list_queued_messages!(conversation.id, actor: user)

    assert queued_id == queued.id

    # Trigger turn 1. This is the in-flight turn.
    send_user_message(conversation, user, @first_text)

    # Turn 1 completes -> PersistencePlugin auto-flush promotes the queued
    # message and redispatches it as turn 2.
    assert_response_complete()

    # Turn 2 (the flushed steering message) completes.
    assert_response_complete()

    # The queue has fully drained.
    assert Chat.list_queued_messages!(conversation.id, actor: user) == []

    # The previously-queued message is now a delivered (:complete) user message.
    user_messages = conversation_messages(conversation.id, user, :user)

    delivered =
      Enum.find(user_messages, fn m ->
        m.id == queued.id and m.status == :complete and m.text == @queued_text
      end)

    assert delivered,
           "Expected the queued message to be promoted to a :complete user message. " <>
             "Got user messages: #{inspect(Enum.map(user_messages, &{&1.id, &1.status, &1.text}))}"

    # Both turns produced an agent response (turn 1 + the auto-flushed turn 2).
    agent_messages = conversation_messages(conversation.id, user, :agent)

    complete_agent_messages =
      Enum.filter(agent_messages, &(&1.status == :complete))

    assert length(complete_agent_messages) >= 2,
           "Expected at least 2 complete agent responses (turn 1 + auto-flushed turn 2), " <>
             "got #{length(complete_agent_messages)}: " <>
             "#{inspect(Enum.map(agent_messages, &{&1.status, &1.message_type}))}"
  end

  # Load all messages for a conversation with a given role, oldest-first.
  # Direct resource read (actor-scoped): robust and avoids keyset pagination
  # unwrapping from the paginated code interface.
  defp conversation_messages(conversation_id, actor, role) do
    Magus.Chat.Message
    |> Ash.Query.filter(conversation_id == ^conversation_id and role == ^role)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(actor: actor)
  end
end
