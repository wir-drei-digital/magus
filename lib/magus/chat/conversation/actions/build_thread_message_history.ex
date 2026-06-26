defmodule Magus.Chat.Conversation.Actions.BuildThreadMessageHistory do
  @moduledoc """
  Builds merged LLM message history for a thread conversation.

  Reads parent conversation messages up to the branch point (using the
  branched_at timestamp), then appends the thread's own messages.
  Recovery logic (interrupted turns) applies only to the thread's messages.
  """

  use Ash.Resource.Actions.Implementation

  # Limit parent context to leave room for thread messages
  @max_parent_messages 15
  @max_thread_messages 20

  @impl true
  def run(input, _opts, _context) do
    thread_id = input.arguments.conversation_id
    current_message_id = input.arguments[:current_message_id]
    is_multiplayer = input.arguments[:is_multiplayer] || false
    ai_actor = %Magus.Agents.Support.AiAgent{}

    # Load thread conversation to get parent info
    thread = Magus.Chat.get_conversation!(thread_id, actor: ai_actor)

    # Phase 1: Parent messages up to branch point (no recovery)
    # Limit parent segment separately to avoid crowding out thread messages
    parent_llm_messages =
      if thread.parent_conversation_id && thread.branched_at do
        Magus.Chat.Message
        |> Ash.Query.for_read(:for_llm_context, %{
          conversation_id: thread.parent_conversation_id,
          cutoff_at: thread.branched_at,
          recent_limit: @max_parent_messages
        })
        |> Ash.Query.load(as_llm_message: [is_multiplayer: is_multiplayer])
        |> Ash.read!(actor: ai_actor)
        |> Enum.reverse()
        |> Enum.map(& &1.as_llm_message)
        |> Enum.reject(&is_nil/1)
      else
        []
      end

    # Phase 2: Thread's own messages (with recovery via standard build_message_history)
    # Thread messages are kept in full (up to the standard limit)
    thread_llm_messages =
      Magus.Chat.build_message_history!(
        thread_id,
        current_message_id,
        is_multiplayer
      )
      |> Enum.take(-@max_thread_messages)

    # Merge: parent context first, then thread messages
    {:ok, parent_llm_messages ++ thread_llm_messages}
  end
end
