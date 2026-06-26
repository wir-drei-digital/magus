defmodule Magus.Chat.CompactContextTriggerTest do
  @moduledoc """
  Tests for the `:compact_context` Oban trigger work action
  (`Magus.Chat.ContextWindow.:run_compaction`).

  The trigger work runs synchronously: we drive it by calling the
  `:run_compaction` update action directly on a `:pending` ContextWindow row
  (Oban is in `testing: :manual`, so the enqueued job is never executed for us).
  The LLM summarizer is mocked via `Magus.Test.Mocks.LLMMock`, exactly as the
  Task 16 summarizer test does.
  """
  use Magus.ResourceCase, async: true
  require Ash.Query

  import Mox

  alias Magus.Chat.ContextWindow
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  @tail ContextWindow.config(:compaction_tail)

  setup do
    user = generate(user())
    conv = generate(conversation(actor: user))
    %{user: user, conv: conv}
  end

  # Create `count` text messages oldest-first and return them in chronological
  # order (the generator inserts sequentially so inserted_at is ascending).
  defp seed_messages(user, conv, count) do
    for i <- 1..count do
      generate(message(actor: user, conversation_id: conv.id, text: "message number #{i}"))
    end
  end

  defp pending_window(conv) do
    {:ok, cw} =
      Magus.Chat.get_or_create_context_window(conv.id, actor: %Magus.Agents.Support.AiAgent{})

    cw
    |> Ash.Changeset.for_update(:request_compaction, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp run_compaction!(cw) do
    cw
    |> Ash.Changeset.for_update(:run_compaction, %{}, authorize?: false)
    |> Ash.update!()
  end

  describe ":run_compaction work action" do
    test "summarizes the older slice, advances the pointer, and returns to :idle", %{
      user: user,
      conv: conv
    } do
      n = @tail + 4
      msgs = seed_messages(user, conv, n)

      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("the stubbed summary")
      end)

      cw = pending_window(conv)
      assert cw.compaction_status == :pending

      compacted = run_compaction!(cw)

      # Summary stored, count is everything but the recency tail.
      assert compacted.summary == "the stubbed summary"
      assert compacted.summary_message_count == n - @tail

      # Pointer advanced to the first message of the kept tail (the (N-K+1)th).
      tail_head = Enum.at(msgs, n - @tail)
      assert compacted.window_start_message_id == tail_head.id
      assert compacted.window_start_at == tail_head.inserted_at

      assert compacted.compaction_status == :idle

      # The kept tail is exactly the last K messages: floor == first of the tail.
      kept_tail = Enum.drop(msgs, n - @tail)
      assert length(kept_tail) == @tail
      assert hd(kept_tail).id == compacted.window_start_message_id
    end

    test "transitions to :failed when the summarizer returns an error", %{
      user: user,
      conv: conv
    } do
      seed_messages(user, conv, @tail + 3)

      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        {:error, :rate_limited}
      end)

      cw = pending_window(conv)
      compacted = run_compaction!(cw)

      assert compacted.compaction_status == :failed
      # Pointer/summary untouched on failure.
      assert is_nil(compacted.summary)
      assert is_nil(compacted.window_start_message_id)
    end

    test "settles to :idle (no-op) when the summarizer returns a nil-message response", %{
      user: user,
      conv: conv
    } do
      # A message-less response makes ReqLLM.Response.text/1 return nil. Coalesced
      # to "" at the source, this routes through the existing {:ok, ""} no-op
      # branch instead of raising CaseClauseError (which would stick :pending).
      MagusWeb.Endpoint.subscribe("agents:#{conv.id}")
      seed_messages(user, conv, @tail + 3)

      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_nil_response()
      end)

      cw = pending_window(conv)
      compacted = run_compaction!(cw)

      # No-op settle: terminal :idle, nothing stored, pointer untouched.
      assert compacted.compaction_status == :idle
      assert is_nil(compacted.summary)
      assert is_nil(compacted.window_start_message_id)

      # The unlock broadcast still fires so the composer is not left locked.
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    test "settles to :failed (and still broadcasts) when the summarizer raises", %{
      user: user,
      conv: conv
    } do
      # A raise inside the LLM call is caught by safe_summarize/1 and mapped to
      # {:error, _} -> :failed. The row must never be left stuck at :pending, and
      # the after_action unlock broadcast must still fire.
      MagusWeb.Endpoint.subscribe("agents:#{conv.id}")
      seed_messages(user, conv, @tail + 3)

      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        raise "boom from the summarizer"
      end)

      cw = pending_window(conv)
      compacted = run_compaction!(cw)

      assert compacted.compaction_status == :failed
      assert is_nil(compacted.summary)
      assert is_nil(compacted.window_start_message_id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    test "settles to :idle without a summary when history is <= the tail", %{
      user: user,
      conv: conv
    } do
      # N <= K: nothing to summarize, so the LLM must not be called
      # (no expect/3 set up — verify_on_exit! would fail on any call).
      seed_messages(user, conv, @tail)

      cw = pending_window(conv)
      compacted = run_compaction!(cw)

      assert compacted.compaction_status == :idle
      assert is_nil(compacted.summary)
      assert compacted.summary_message_count == 0
      assert is_nil(compacted.window_start_message_id)
    end
  end
end
