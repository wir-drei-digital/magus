defmodule Magus.Eval.Subject.Live do
  @moduledoc """
  The real black-box boundary. Drives the actual agent pipeline.

  Unlike the brief's original design, `ingest/2` does NOT insert history
  messages into the conversation. Instead it runs memory extraction directly
  over the (user, assistant) turn strings, writing recallable memories.
  Keeping the query conversation free of history is intentional: it makes this
  a real memory test (the agent must recall from memory, not read prior turns
  from the context window).

  Lives in test support because it depends on `Magus.Generators`.
  """
  @behaviour Magus.Eval.Subject

  require Ash.Query
  require Logger

  alias Magus.Chat

  @response_timeout 90_000

  @impl true
  def reset(ctx) do
    conversation =
      Magus.Generators.generate(
        Magus.Generators.conversation(
          actor: ctx.user,
          selected_model_id: ctx.model.id,
          chat_mode: :chat
        )
      )

    {:ok, Map.put(ctx, :conversation, conversation)}
  end

  @impl true
  def ingest(ctx, items) do
    items
    |> to_windows()
    |> Enum.each(fn pairs -> extract_window(ctx, pairs) end)

    settle_extraction()
    {:ok, ctx}
  end

  # Group ingest items into extraction windows, then pair user->agent turns
  # within each window. Items carrying a :session tag (LongMemEval) become one
  # window per session; untagged items (small benchmarks) form a single window.
  # A session replayed instantly is one production debounce window, so this
  # mirrors production: extraction runs once per window over all its turns, and
  # it keeps the same window shape the recorded baseline used.
  defp to_windows(items) do
    if Enum.any?(items, &Map.has_key?(&1, :session)) do
      items
      |> Enum.chunk_by(&Map.get(&1, :session))
      |> Enum.map(&pair_turns/1)
      |> Enum.reject(&(&1 == []))
    else
      case pair_turns(items) do
        [] -> []
        pairs -> [pairs]
      end
    end
  end

  # Windowed extraction (post-hardening): pass every turn-pair of the window as
  # `turns`, matching production's "extract all turns since the watermark". The
  # pre-hardening baseline passed only the window's last pair (mirroring the old
  # load_last_turn); that difference is exactly the extraction-window fix under test.
  defp extract_window(ctx, pairs) do
    turns =
      Enum.map(pairs, fn {user_text, agent_text} ->
        %{"user" => user_text, "agent" => agent_text}
      end)

    force_extract(ctx, turns)
  end

  @impl true
  def query(ctx, question) do
    conv = ctx.conversation
    MagusWeb.Endpoint.subscribe("agents:#{conv.id}")

    {:ok, _msg} =
      Chat.send_user_message(%{text: question, conversation_id: conv.id}, actor: ctx.user)

    case wait_for_complete(@response_timeout) do
      :ok ->
        answer = latest_agent_text(conv.id)
        {:ok, %{answer: answer || "", meta: %{}}}

      :timeout ->
        {:error, :response_timeout}
    end
  end

  # --- helpers ---

  # Pairs items into {user_text, agent_text} tuples: a :user item followed by
  # the next :assistant item. An unpaired user item gets agent_text = "".
  # Leading or stray :assistant items (no preceding user) are ignored.
  defp pair_turns(items), do: pair_turns(items, [])

  defp pair_turns([], acc), do: Enum.reverse(acc)

  defp pair_turns([%{role: :user, text: user_text} | rest], acc) do
    case rest do
      [%{role: :assistant, text: agent_text} | tail] ->
        pair_turns(tail, [{user_text, agent_text} | acc])

      _ ->
        pair_turns(rest, [{user_text, ""} | acc])
    end
  end

  defp pair_turns([_other | rest], acc), do: pair_turns(rest, acc)

  # ExtractTurnMemories exposes run/2 (params, context); context is unused, so
  # we pass an empty map. It runs synchronously inline (no Task spawn) and
  # persists memories before returning. Wrap so one failure does not abort ingest.
  defp force_extract(ctx, turns) do
    Magus.Agents.Actions.ExtractTurnMemories.run(
      %{
        user_id: to_string(ctx.user.id),
        conversation_id: to_string(ctx.conversation.id),
        turns: turns,
        allow_global_memories: true
      },
      %{}
    )
  rescue
    e ->
      Logger.warning("Subject.Live force_extract failed: #{Exception.message(e)}")
      :ok
  end

  # Best-effort: drain the queues that turn extracted memories into recallable
  # state. Memory embeddings are produced inline during extraction; the Super
  # Brain graph build (and its embeddings) are enqueued, so drain them too.
  defp settle_extraction do
    Oban.drain_queue(queue: :memory_extraction)
    Oban.drain_queue(queue: :super_brain_extraction)
    :ok
  rescue
    e ->
      Logger.warning("Subject.Live settle_extraction failed: #{Exception.message(e)}")
      :ok
  end

  # Raw receive (this runs outside ExUnit, so no assert_receive). Ignore other
  # agent_signal broadcasts and keep waiting until response.complete or timeout.
  # The budget is a single monotonic deadline: an ignored broadcast does NOT
  # reset it, so the total wait is bounded by `timeout` regardless of how many
  # broadcasts arrive. Public (with @doc false) so the deadline behavior can be
  # unit-tested.
  @doc false
  def wait_for_complete(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_until(deadline)
  end

  defp wait_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        %Phoenix.Socket.Broadcast{event: "agent_signal", payload: %{type: "response.complete"}} ->
          :ok

        %Phoenix.Socket.Broadcast{event: "agent_signal"} ->
          wait_until(deadline)
      after
        remaining -> :timeout
      end
    end
  end

  # Mirrors Magus.LiveE2E.Assertions.latest_agent_message/2: persistence lags
  # the response.complete signal, so retry a few times.
  defp latest_agent_text(conversation_id, retries \\ 10) do
    result =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and role == :agent)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> List.first()

    case {result, retries} do
      {nil, n} when n > 0 ->
        Process.sleep(200)
        latest_agent_text(conversation_id, retries - 1)

      {nil, _} ->
        nil

      {msg, _} ->
        msg.text
    end
  end
end
