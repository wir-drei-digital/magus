defmodule Magus.Agents.Plugins.PersistencePlugin do
  @moduledoc """
  Plugin that handles response persistence and request lifecycle signals.

  Translates outbound ReAct signals related to response completion and
  request lifecycle into PubSub broadcasts and database writes:

  | ReAct Signal            | Behaviour                                               |
  |-------------------------|---------------------------------------------------------|
  | `ai.llm.response`      | Persist response to DB + broadcast `text.complete`      |
  | `ai.request.completed`  | Broadcast `state.change(:idle)` + `response.complete`   |
  | `ai.request.failed`     | Broadcast error (unless cancelled) + idle + complete    |

  This is one of several focused plugins extracted from the monolithic conversation skill.
  It handles ONLY response persistence and request lifecycle -- no streaming, no inbound
  transformation, no tool events.

  ## Support Modules

  - `Helpers` -- state extraction and formatting utilities
  - `ErrorMessages` -- user-friendly error event creation
  - `Persistence` -- response database writes via MessagePersistence
  """

  use Jido.Plugin,
    name: "persistence",
    state_key: :persistence,
    actions: [],
    description: "Response persistence and request lifecycle for conversation agents",
    category: "magus",
    tags: ["conversation", "persistence", "response-lifecycle"],
    signal_patterns: [
      "ai.llm.response",
      "ai.request.completed",
      "ai.request.failed"
    ]

  require Ash.Query
  require Logger

  alias Magus.Agents.Plugins.Support.{AttachmentStash, ErrorMessages, Helpers, Persistence}
  alias Magus.Agents.Signals
  alias Magus.Agents.Steering

  # ============================================================================
  # Plugin Callbacks
  # ============================================================================

  @impl Jido.Plugin
  def mount(_agent, config) do
    {:ok, %{config: config}}
  end

  @impl Jido.Plugin
  def handle_signal(signal, context) do
    agent = context[:agent]
    conversation_id = Helpers.get_conversation_id(agent)

    case signal.type do
      "ai.llm.response" ->
        handle_llm_response(signal, conversation_id, agent)

      "ai.request.completed" ->
        handle_request_completed(signal, conversation_id, agent)

      "ai.request.failed" ->
        handle_request_failed(signal, conversation_id, agent)

      _ ->
        Logger.debug("[PersistencePlugin] Unhandled signal: #{signal.type}")
        {:ok, :continue}
    end
  end

  # ============================================================================
  # Signal Handlers
  # ============================================================================

  defp handle_llm_response(signal, conversation_id, agent) do
    data = signal.data || %{}
    call_id = data[:call_id] || data["call_id"]
    turn = extract_turn_result(data[:result] || data["result"])

    projected_text =
      Helpers.first_non_blank([
        turn[:projected_text],
        turn["projected_text"],
        turn[:text],
        turn["text"]
      ])

    usage = turn[:usage] || turn["usage"] || data[:usage] || data["usage"] || %{}

    request_id =
      Helpers.resolve_request_id(data, call_id) ||
        turn[:request_id] ||
        turn["request_id"]

    message_id = Helpers.resolve_turn_message_id(data, agent, request_id, call_id)

    opts = Helpers.custom_agent_opts(agent)

    if Helpers.valid_message_id?(message_id) do
      # Persist FIRST, then decide whether to finalize the streaming bubble.
      # The previous order broadcast `text.complete` unconditionally — when the
      # turn was empty the persist step silently dropped it, leaving a blank
      # bubble in the UI with no backing DB row ("empty message, no trace").
      case Persistence.persist_response(agent, turn, message_id, request_id) do
        {:skipped, :empty} ->
          Logger.warning(
            "[PersistencePlugin] Dropped empty LLM response for conversation " <>
              "#{conversation_id} (message_id=#{message_id}, request_id=#{inspect(request_id)})"
          )

          Signals.turn_empty(conversation_id, message_id, request_id)

        _persisted ->
          Signals.text_complete(conversation_id, message_id, projected_text, usage, opts)
      end
    end

    {:ok, :continue}
  end

  defp handle_request_completed(signal, conversation_id, _agent) do
    data = signal.data || %{}
    request_id = data[:request_id] || data["request_id"]

    Signals.state_change(conversation_id, :idle)

    response_payload =
      if Helpers.valid_message_id?(request_id) do
        %{triggering_message_id: request_id}
      else
        %{}
      end

    Signals.response_complete(conversation_id, response_payload)

    maybe_flush_queue(conversation_id)

    {:ok, :continue}
  end

  @doc "Drain any queued steering messages for the conversation, asynchronously."
  def maybe_flush_queue(conversation_id) when is_binary(conversation_id) do
    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      Steering.flush_conversation(conversation_id)
    end)

    :ok
  end

  def maybe_flush_queue(_), do: :ok

  # Mirror of Magus.Agents.Recovery's interrupted-message cleanup: mark any
  # messages still in `:streaming` for this conversation as `:error`.
  defp mark_streaming_messages_error(conversation_id) when is_binary(conversation_id) do
    streaming_messages =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and status == :streaming)
      |> Ash.read!(authorize?: false)

    if streaming_messages != [] do
      Ash.bulk_update(
        streaming_messages,
        :mark_error,
        %{
          error: %{
            "reason" => "request_failed",
            "detail" => "Streaming row failed on ai.request.failed."
          }
        },
        authorize?: false
      )
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[PersistencePlugin] Failed to mark streaming messages as error for " <>
          "#{conversation_id}: #{inspect(error)}"
      )

      :ok
  end

  defp mark_streaming_messages_error(_), do: :ok

  defp handle_request_failed(signal, conversation_id, agent) do
    data = signal.data || %{}
    error = data[:error] || data["error"]
    request_id = data[:request_id] || data["request_id"]

    # Discard any attachments stashed by tools during the failed turn so they
    # don't get grafted onto the next successful response.
    AttachmentStash.clear()

    message_id =
      Helpers.get_current_message_id(agent) ||
        if(request_id, do: Helpers.response_id_for_request(request_id))

    if match?({:cancelled, _}, error) do
      Logger.info("Request cancelled for conversation #{conversation_id}")
      # Cancelling an in-flight turn drains the steering queue immediately so
      # queued messages are promoted + redispatched without waiting for the
      # (never-arriving) ai.request.completed signal.
      maybe_flush_queue(conversation_id)
    else
      error_message = Helpers.format_error(error)
      Logger.error("Request failed for conversation #{conversation_id}: #{error_message}")
      Signals.error(conversation_id, message_id, :request_failed, error_message)

      # Defensive: if a partial response row was ever left in `:streaming`,
      # flip it to `:error` now so the turn always leaves a trace, rather than
      # waiting up to ~1h for the `cleanup_stale_streaming` cron.
      mark_streaming_messages_error(conversation_id)

      ErrorMessages.create_error_event(conversation_id, :request_failed, error)
    end

    Signals.state_change(conversation_id, :idle)

    Signals.response_complete(conversation_id, %{
      triggering_message_id: request_id || Helpers.get_parent_message_id(agent)
    })

    {:ok, :continue}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp extract_turn_result({:ok, %{} = result}), do: result
  defp extract_turn_result({:ok, %{} = result, _effects}), do: result
  defp extract_turn_result(%{} = result), do: result
  defp extract_turn_result(_), do: %{}
end
