defmodule Magus.Chat.ContextWindow.Changes.RunCompaction do
  @moduledoc """
  Performs a single compaction pass on a `Magus.Chat.ContextWindow` row.

  Invoked by the `:compact_context` Oban trigger (and reachable directly for
  tests) once a window's `compaction_status` is `:pending`. The change runs the
  whole pass synchronously inside the `:run_compaction` action so the worker's
  success/failure maps cleanly onto the state machine:

    1. Load the in-window text messages for the conversation (floor-aware, as the
       AI agent actor — mirrors `BuildMessageHistory`'s read).
    2. Keep a recency tail of `K = config(:compaction_tail)` messages.
       * If there are `<= K` messages there is nothing to summarize: settle back
         to `:idle` as a no-op (no summary stored, pointer untouched).
       * Otherwise summarize the older slice (`msgs - tail`) via
         `SummarizeWindow.summarize/1` and advance the window floor to the first
         message of the tail.
    3. On a non-empty summary: store it, advance the pointer, return to `:idle`.
       On an empty summary (`{:ok, ""}`): treat as a no-op and settle to `:idle`.
       On an LLM error (`{:error, _}` or a raise): transition to `:failed`.

  The whole pass is wrapped so ANY raise (the LLM call, the windowed message
  read, an unexpected summarizer shape) force-changes `compaction_status` to
  `:failed` and lets the action complete normally rather than escaping and
  leaving the row stuck at `:pending` (a permanently locked composer). On every
  settle (no-op, success, or failure) we best-effort broadcast
  `context_updated/2` so both composers unlock and the chat view's context donut
  refreshes. The broadcast is a top-level `after_action`, so it is
  branch-agnostic: because every path now completes the action, it fires no
  matter which terminal state the pass reaches.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Support.AiAgent
  alias Magus.Chat.ContextWindow
  alias Magus.Chat.Conversation.Actions.SummarizeWindow

  @impl true
  def change(changeset, _opts, _context) do
    conversation_id = changeset.data.conversation_id

    changeset
    |> Ash.Changeset.before_action(&compact/1)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      # Broadcast on every settle (no-op, success, failure) so both composers
      # unlock regardless of which terminal state the pass reached.
      _ = safe_broadcast(conversation_id)
      {:ok, record}
    end)
  end

  # Outermost guard: any raise anywhere in the pass (the windowed read, the LLM
  # call, the persist path) force-changes :failed so the action still completes
  # and the after_action unlock broadcast fires. Without this a raise escapes the
  # action, the broadcast never runs, and the row stays :pending forever.
  defp compact(changeset) do
    do_compact(changeset)
  rescue
    e ->
      Logger.warning(
        "RunCompaction crashed for #{changeset.data.conversation_id}: #{Exception.message(e)}"
      )

      Ash.Changeset.force_change_attribute(changeset, :compaction_status, :failed)
  end

  defp do_compact(changeset) do
    cw = changeset.data
    k = ContextWindow.config(:compaction_tail)
    msgs = load_window_messages(cw)

    cond do
      length(msgs) <= k ->
        # Not enough history to summarize: settle back to :idle untouched.
        settle_idle(changeset)

      true ->
        {to_summarize, tail} = Enum.split(msgs, length(msgs) - k)
        new_floor = hd(tail)
        do_summarize(changeset, to_summarize, new_floor, cw.conversation_id)
    end
  end

  defp do_summarize(changeset, to_summarize, new_floor, conversation_id) do
    case safe_summarize(to_summarize) do
      {:ok, summary} when is_binary(summary) and summary != "" ->
        changeset
        |> Ash.Changeset.force_change_attribute(:summary, summary)
        |> Ash.Changeset.force_change_attribute(:summary_message_count, length(to_summarize))
        |> Ash.Changeset.force_change_attribute(:window_start_message_id, new_floor.id)
        |> Ash.Changeset.force_change_attribute(:window_start_at, new_floor.inserted_at)
        |> Ash.Changeset.force_change_attribute(:compaction_status, :idle)

      {:ok, ""} ->
        # Empty summary: nothing useful to store, treat as a no-op.
        settle_idle(changeset)

      {:error, reason} ->
        Logger.warning("RunCompaction failed for #{conversation_id}: #{inspect(reason)}")
        Ash.Changeset.force_change_attribute(changeset, :compaction_status, :failed)

      other ->
        # Belt-and-braces: any unexpected summarizer return settles :failed
        # instead of raising CaseClauseError (which the outer compact/1 rescue
        # would still catch, but settling here keeps the failure attributable).
        Logger.warning(
          "RunCompaction unexpected summarizer result #{inspect(other)} for #{conversation_id}"
        )

        Ash.Changeset.force_change_attribute(changeset, :compaction_status, :failed)
    end
  end

  # Never let an LLM client raise escape: a crash would leave the row stuck at
  # :pending (a locked composer). Map any raise to {:error, _} so the row
  # transitions to :failed. The outer compact/1 rescue is the final backstop.
  defp safe_summarize(messages) do
    SummarizeWindow.summarize(messages)
  rescue
    e -> {:error, e}
  end

  defp settle_idle(changeset) do
    Ash.Changeset.force_change_attribute(changeset, :compaction_status, :idle)
  end

  # Load the conversation's in-window text messages, floor-aware, as the AI agent
  # actor — same read shape as BuildMessageHistory (message_type == :message,
  # non-empty text). recent_limit caps a very large :compact window at the
  # backstop so the summary model's context cannot be exceeded (which would stick
  # the row at :failed). recent_limit sorts desc + limits at the DB level; we
  # reverse back to chronological (oldest-first) order, matching how
  # BuildMessageHistory handles this; the compaction split/tail logic depends on
  # it. For N within the backstop the result (and the pointer math) is unchanged.
  defp load_window_messages(cw) do
    Magus.Chat.Message
    |> Ash.Query.for_read(:for_llm_context, %{
      conversation_id: cw.conversation_id,
      since_at: cw.window_start_at,
      recent_limit: ContextWindow.config(:message_count_backstop)
    })
    |> Ash.read!(actor: %AiAgent{})
    |> Enum.reverse()
  end

  defp safe_broadcast(conversation_id) do
    Signals.context_updated(conversation_id, %{})
  rescue
    _ -> :ok
  end
end
