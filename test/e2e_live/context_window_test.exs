defmodule Magus.LiveE2E.ContextWindowTest do
  @moduledoc """
  Verifies the context-window seam end to end: a real turn must emit `ai.context`
  (handled by `ContextPlugin`), which persists a `context_windows` snapshot and
  broadcasts `context.updated` on the conversation topic.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :chat

  describe "context window seam" do
    test "a real turn persists a context snapshot and broadcasts context.updated",
         %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "Say hi in one word.")

      # ContextPlugin re-broadcasts ai.context as context.updated on the topic.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent_signal",
                       payload: %{type: "context.updated"} = payload
                     },
                     60_000,
                     "Expected a context.updated broadcast within 60s"

      # The snapshot broadcast carries the assembled breakdown.
      assert is_map(payload)

      assert_response_complete()

      # The persisted snapshot row records a non-empty resting context.
      {:ok, cw} = Magus.Chat.get_context_window(conversation.id, actor: user)

      assert cw.last_total_tokens && cw.last_total_tokens > 0,
             "Expected last_total_tokens > 0, got: #{inspect(cw.last_total_tokens)}"

      assert is_integer(cw.last_max_context) and cw.last_max_context > 0
      assert is_binary(cw.last_model_key)
      assert is_map(cw.last_breakdown)
    end
  end
end
