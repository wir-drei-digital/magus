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
    # Per-case isolation. LongMemEval assumes each question's haystack stands
    # alone, but user-scoped memories (and the Super Brain state derived from
    # them) live on the shared eval user and would otherwise accumulate
    # across cases. Wipe memories, claims, episodes, and the user's graphs.
    wipe_user_state(ctx.user)

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
    |> pair_turns()
    |> Enum.each(fn {user_text, agent_text} ->
      force_extract(ctx, user_text, agent_text)
    end)

    promote_memories_to_user_scope(ctx)
    settle_extraction()
    {:ok, ctx}
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

  # LongMemEval haystacks are PAST sessions: their knowledge belongs in the
  # durable user tier (what production distills across conversations), not in
  # the query conversation's local working memory. User scope is also the
  # only tier the Super Brain ingests (enqueue_super_brain_extraction is a
  # no-op for :local), so this is what lets an eval run exercise the graph.
  # The local originals are destroyed so the conversation-local channel does
  # not double-inject the same content.
  defp promote_memories_to_user_scope(ctx) do
    case Magus.Memory.list_memories_for_conversation(ctx.conversation.id, actor: ctx.user) do
      {:ok, locals} ->
        Enum.each(locals, fn m ->
          case Magus.Memory.create_user_memory(
                 ctx.user.id,
                 nil,
                 m.name,
                 %{summary: m.summary, content: m.content, kind: m.kind},
                 actor: ctx.user
               ) do
            {:ok, _} -> Magus.Memory.destroy_memory(m, actor: ctx.user)
            {:error, e} -> Logger.warning("promote_memories: create_user failed: #{inspect(e)}")
          end
        end)

      other ->
        Logger.warning("promote_memories: list failed: #{inspect(other)}")
    end
  end

  # Wipes the eval user's durable state between cases: user-scoped memories
  # (destroyed WITHOUT the resource action to avoid enqueueing retraction
  # jobs against graphs we drop wholesale below), claims, episodes, super
  # graph rows, and the FalkorDB graphs themselves.
  defp wipe_user_state(user) do
    require Ash.Query

    Magus.Memory.Memory
    |> Ash.Query.filter(user_id == ^user.id and scope in [:user, :agent])
    |> Ash.bulk_destroy!(:destroy, %{},
      authorize?: false,
      return_errors?: false,
      strategy: [:stream],
      notify?: false
    )

    Magus.SuperBrain.Claim
    |> Ash.Query.filter(source_user_id == ^user.id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)

    Magus.SuperBrain.Episode
    |> Ash.Query.filter(source_user_id == ^user.id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)

    Magus.SuperBrain.SuperGraph
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: false)

    Magus.Graph.drop("memories:user:#{user.id}")
    Magus.Graph.drop("super:user:#{user.id}")
    :ok
  rescue
    e ->
      Logger.warning("Subject.Live wipe_user_state failed: #{Exception.message(e)}")
      :ok
  end

  # ExtractTurnMemories exposes run/2 (params, context); context is unused, so
  # we pass an empty map. It runs synchronously inline (no Task spawn) and
  # persists memories before returning. Wrap so one failure does not abort ingest.
  defp force_extract(ctx, user_text, agent_text) do
    Magus.Agents.Actions.ExtractTurnMemories.run(
      %{
        user_id: to_string(ctx.user.id),
        conversation_id: to_string(ctx.conversation.id),
        user_message: user_text,
        agent_response: agent_text
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
    # Recursive: ExtractMemory jobs enqueue follow-up graph builds into the
    # same queue; a plain drain would leave those sitting as available.
    Oban.drain_queue(queue: :super_brain_extraction, with_recursion: true)
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
