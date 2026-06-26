defmodule Magus.Chat.BuildThreadMessageHistoryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "build_thread_message_history/3" do
    test "includes parent messages up to branch point and thread messages" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _msg1 =
        generate(message(actor: user, conversation_id: conversation.id, text: "Parent msg 1"))

      # Small delay to ensure ordering via inserted_at
      Process.sleep(10)

      msg2 =
        generate(message(actor: user, conversation_id: conversation.id, text: "Parent msg 2"))

      Process.sleep(10)

      _msg3 =
        generate(message(actor: user, conversation_id: conversation.id, text: "Parent msg 3"))

      # Create thread branching from msg2
      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: msg2.id
          },
          actor: user
        )

      Process.sleep(10)

      _thread_msg1 =
        generate(message(actor: user, conversation_id: thread.id, text: "Thread msg 1"))

      Process.sleep(10)

      _thread_msg2 =
        generate(message(actor: user, conversation_id: thread.id, text: "Thread msg 2"))

      result = Chat.build_thread_message_history!(thread.id, nil, false)

      assert is_list(result)
      assert length(result) > 0

      # Extract text content from ReqLLM.Message structs
      texts =
        Enum.map(result, fn msg ->
          case msg.content do
            text when is_binary(text) ->
              text

            parts when is_list(parts) ->
              Enum.find_value(parts, "", fn
                %{text: text} -> text
                _ -> nil
              end)

            _ ->
              ""
          end
        end)

      # Parent msg1 and msg2 should be included (up to branch point)
      assert Enum.any?(texts, &String.contains?(&1, "Parent msg 1")),
             "Expected parent msg 1 in history, got: #{inspect(texts)}"

      assert Enum.any?(texts, &String.contains?(&1, "Parent msg 2")),
             "Expected parent msg 2 in history, got: #{inspect(texts)}"

      # Parent msg3 should NOT be included (after branch point)
      refute Enum.any?(texts, &String.contains?(&1, "Parent msg 3")),
             "Parent msg 3 should not be in thread history"

      # Thread messages should be included
      assert Enum.any?(texts, &String.contains?(&1, "Thread msg 1")),
             "Expected thread msg 1 in history, got: #{inspect(texts)}"

      assert Enum.any?(texts, &String.contains?(&1, "Thread msg 2")),
             "Expected thread msg 2 in history, got: #{inspect(texts)}"
    end

    test "returns only thread messages when parent has no messages before branch" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Only one message in parent, which is the branch point
      msg1 = generate(message(actor: user, conversation_id: conversation.id, text: "Only parent"))

      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: msg1.id
          },
          actor: user
        )

      Process.sleep(10)

      _thread_msg =
        generate(message(actor: user, conversation_id: thread.id, text: "Thread reply"))

      result = Chat.build_thread_message_history!(thread.id, nil, false)

      texts =
        Enum.map(result, fn msg ->
          case msg.content do
            text when is_binary(text) ->
              text

            parts when is_list(parts) ->
              Enum.find_value(parts, "", fn
                %{text: text} -> text
                _ -> nil
              end)

            _ ->
              ""
          end
        end)

      # The branch point message should be included
      assert Enum.any?(texts, &String.contains?(&1, "Only parent"))
      # Thread message should be included
      assert Enum.any?(texts, &String.contains?(&1, "Thread reply"))
    end
  end
end
