defmodule Magus.Chat.BuildMessageHistoryTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Chat

  # Extract the text content from a ReqLLM.Message struct (binary or content parts).
  defp text_of(%{content: content}) do
    case content do
      text when is_binary(text) ->
        text

      parts when is_list(parts) ->
        Enum.map_join(parts, "", fn
          %{text: text} when is_binary(text) -> text
          _ -> ""
        end)

      _ ->
        ""
    end
  end

  defp texts(messages), do: Enum.map(messages, &text_of/1)

  # Seed/override fields the public actions don't accept (summary, strategy,
  # window_start_at, last_max_context) on a ContextWindow row.
  defp seed_context_window(conversation_id, fields) do
    {:ok, cw} =
      Chat.get_or_create_context_window(conversation_id, actor: %Magus.Agents.Support.AiAgent{})

    changeset =
      Enum.reduce(fields, Ash.Changeset.for_update(cw, :patch_usage, %{}), fn {k, v}, cs ->
        Ash.Changeset.force_change_attribute(cs, k, v)
      end)

    Ash.update!(changeset)
  end

  describe "build_message_history/3 without a ContextWindow row" do
    test "returns all messages of a short conversation in chronological order" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _m1 = generate(message(actor: user, conversation_id: conversation.id, text: "first"))
      Process.sleep(5)
      _m2 = generate(message(actor: user, conversation_id: conversation.id, text: "second"))
      Process.sleep(5)
      _m3 = generate(message(actor: user, conversation_id: conversation.id, text: "third"))

      result = Chat.build_message_history!(conversation.id, nil, false)
      texts = texts(result)

      assert Enum.any?(texts, &String.contains?(&1, "first"))
      assert Enum.any?(texts, &String.contains?(&1, "second"))
      assert Enum.any?(texts, &String.contains?(&1, "third"))

      # Chronological order preserved.
      idx_first = Enum.find_index(texts, &String.contains?(&1, "first"))
      idx_second = Enum.find_index(texts, &String.contains?(&1, "second"))
      idx_third = Enum.find_index(texts, &String.contains?(&1, "third"))

      assert idx_first < idx_second
      assert idx_second < idx_third
    end
  end

  describe "build_message_history/3 with window_start_at floor" do
    test "excludes messages inserted before the floor" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _old1 = generate(message(actor: user, conversation_id: conversation.id, text: "old one"))
      Process.sleep(10)
      _old2 = generate(message(actor: user, conversation_id: conversation.id, text: "old two"))
      Process.sleep(10)

      floor = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      Process.sleep(10)

      _new1 = generate(message(actor: user, conversation_id: conversation.id, text: "new one"))
      Process.sleep(10)
      _new2 = generate(message(actor: user, conversation_id: conversation.id, text: "new two"))

      seed_context_window(conversation.id, %{window_start_at: floor})

      result = Chat.build_message_history!(conversation.id, nil, false)
      texts = texts(result)

      refute Enum.any?(texts, &String.contains?(&1, "old one"))
      refute Enum.any?(texts, &String.contains?(&1, "old two"))
      assert Enum.any?(texts, &String.contains?(&1, "new one"))
      assert Enum.any?(texts, &String.contains?(&1, "new two"))
    end
  end

  describe "build_message_history/3 with :compact strategy and a summary" do
    test "prepends the summary as the first message; post-floor messages follow" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _pre =
        generate(message(actor: user, conversation_id: conversation.id, text: "before floor"))

      Process.sleep(10)

      floor = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      Process.sleep(10)

      _post1 =
        generate(message(actor: user, conversation_id: conversation.id, text: "after floor 1"))

      Process.sleep(10)

      _post2 =
        generate(message(actor: user, conversation_id: conversation.id, text: "after floor 2"))

      seed_context_window(conversation.id, %{
        strategy: :compact,
        window_start_at: floor,
        summary: "The user discussed cats earlier.",
        summary_message_count: 1
      })

      result = Chat.build_message_history!(conversation.id, nil, false)
      texts = texts(result)

      # First message is the summary prepend.
      assert String.contains?(List.first(texts), "[Summary of earlier conversation]")
      assert String.contains?(List.first(texts), "The user discussed cats earlier.")

      # Pre-floor message excluded; post-floor messages present and ordered.
      refute Enum.any?(texts, &String.contains?(&1, "before floor"))
      assert Enum.any?(texts, &String.contains?(&1, "after floor 1"))
      assert Enum.any?(texts, &String.contains?(&1, "after floor 2"))

      idx_summary = 0
      idx_post1 = Enum.find_index(texts, &String.contains?(&1, "after floor 1"))
      idx_post2 = Enum.find_index(texts, &String.contains?(&1, "after floor 2"))

      assert idx_summary < idx_post1
      assert idx_post1 < idx_post2
    end
  end

  describe "build_message_history/3 with :rolling strategy exceeding the token budget" do
    test "drops the oldest messages, keeps the newest and at least compaction_tail" do
      tail = Magus.Chat.ContextWindow.config(:compaction_tail)
      fraction = Magus.Chat.ContextWindow.config(:rolling_target_fraction)

      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Each message ~250 chars => ~62 tokens. With last_max_context = 100 and
      # fraction 0.6 the budget is ~60 tokens, so a single message exceeds it and
      # trimming collapses down to the compaction_tail floor.
      body = String.duplicate("x", 250)

      count = tail + 8

      ordered_texts =
        for i <- 1..count do
          text = "msg#{String.pad_leading(Integer.to_string(i), 3, "0")} #{body}"
          generate(message(actor: user, conversation_id: conversation.id, text: text))
          Process.sleep(3)
          text
        end

      # Tiny context window so the rolling budget is trivially exceeded.
      seed_context_window(conversation.id, %{
        strategy: :rolling,
        last_max_context: 100
      })

      # Sanity: the budget really is small relative to one message.
      assert round(fraction * 100) < 250

      result = Chat.build_message_history!(conversation.id, nil, false)
      texts = texts(result)

      # Keeps exactly the compaction_tail most-recent messages (budget forces max drop).
      assert length(texts) == tail

      kept_oldest_idx = count - tail + 1
      newest = List.last(ordered_texts)

      # Newest retained.
      assert Enum.any?(texts, &String.contains?(&1, newest))
      # Oldest dropped.
      assert Enum.all?(texts, fn t -> not String.contains?(t, "msg001") end)

      # The retained set is the contiguous most-recent tail, in order.
      expected_kept =
        ordered_texts |> Enum.drop(kept_oldest_idx - 1)

      assert texts == expected_kept
    end

    test "keeps all messages when under the token budget" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _m1 = generate(message(actor: user, conversation_id: conversation.id, text: "short a"))
      Process.sleep(5)
      _m2 = generate(message(actor: user, conversation_id: conversation.id, text: "short b"))

      # Large context => budget far exceeds the tiny messages.
      seed_context_window(conversation.id, %{strategy: :rolling, last_max_context: 200_000})

      result = Chat.build_message_history!(conversation.id, nil, false)
      texts = texts(result)

      assert Enum.any?(texts, &String.contains?(&1, "short a"))
      assert Enum.any?(texts, &String.contains?(&1, "short b"))
    end
  end
end
