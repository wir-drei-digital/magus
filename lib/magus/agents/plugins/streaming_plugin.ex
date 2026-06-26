defmodule Magus.Agents.Plugins.StreamingPlugin do
  @moduledoc """
  Plugin that translates ReAct streaming signals to Magus PubSub broadcasts.

  Pure signal-to-broadcast translation — NO DB writes, NO state mutations.

  | ReAct Signal              | Magus PubSub Event                        |
  |---------------------------|--------------------------------------------|
  | `ai.llm.delta`            | `text.chunk` (content) or `thinking.chunk` (thinking) |
  | `ai.request.started`      | `state.change(:thinking)` or `state.change(:reasoning)` |
  | `ai.llm.turn.started`     | `turn.started`                             |
  | `ai.llm.turn.completed`   | `turn.completed` (+ `state.change(:running_tools)` for tool turns) |
  """

  use Jido.Plugin,
    name: "streaming",
    state_key: :streaming,
    actions: [],
    description: "Translates ReAct streaming signals to Magus PubSub broadcasts",
    category: "magus",
    tags: ["streaming", "pubsub", "signal-translation"],
    signal_patterns: [
      "ai.llm.delta",
      "ai.llm.turn.started",
      "ai.llm.turn.completed",
      "ai.request.started"
    ]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Plugins.Support.RunRelay
  alias Magus.Agents.Signals

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
      "ai.llm.delta" ->
        handle_llm_delta(signal, conversation_id, agent)

      "ai.request.started" ->
        handle_request_started(conversation_id, agent)

      "ai.llm.turn.started" ->
        handle_llm_turn_started(signal, conversation_id)

      "ai.llm.turn.completed" ->
        handle_llm_turn_completed(signal, conversation_id)

      _ ->
        Logger.debug("[StreamingPlugin] Unhandled signal: #{signal.type}")
        {:ok, :continue}
    end
  end

  # ============================================================================
  # Signal Handlers
  # ============================================================================

  defp handle_llm_delta(signal, conversation_id, agent) do
    data = signal.data || %{}
    delta = data[:delta] || data["delta"] || ""
    chunk_type = data[:chunk_type] || data["chunk_type"] || :content
    call_id = data[:call_id] || data["call_id"]
    request_id = Helpers.resolve_request_id(data, call_id)
    message_id = Helpers.resolve_turn_message_id(data, agent, request_id, call_id)

    strategy_state = Helpers.get_strategy_state(agent)

    case chunk_type do
      :thinking ->
        accumulated =
          data[:text] || data["text"] || strategy_state[:streaming_thinking] || ""

        if Helpers.valid_message_id?(message_id) and (delta != "" or accumulated != "") do
          Signals.state_change(conversation_id, :reasoning)
          Signals.thinking_chunk(conversation_id, message_id, accumulated, delta)
        end

      :tool_call ->
        Signals.state_change(conversation_id, :thinking)

      _ ->
        accumulated =
          data[:text] || data["text"] || strategy_state[:streaming_text] || ""

        if Helpers.valid_message_id?(message_id) and delta != "" do
          Signals.text_chunk(
            conversation_id,
            message_id,
            accumulated,
            delta,
            Helpers.custom_agent_opts(agent)
          )

          # Relay text delta to parent conversation if this is a sub-agent
          maybe_relay_text_delta(conversation_id, delta)
        end
    end

    {:ok, :continue}
  end

  defp handle_request_started(conversation_id, agent) do
    state = agent.state || %{}
    mode = state[:mode] || :chat

    if mode == :reasoning do
      Signals.state_change(conversation_id, :reasoning)
    else
      Signals.state_change(conversation_id, :thinking)
    end

    {:ok, :continue}
  end

  defp handle_llm_turn_started(signal, conversation_id) do
    data = signal.data || %{}
    turn_id = data[:turn_id] || data["turn_id"]
    model = data[:model] || data["model"]

    Signals.turn_started(conversation_id, %{
      request_id: data[:request_id] || data["request_id"],
      turn_id: turn_id,
      iteration: data[:iteration] || data["iteration"],
      call_id: data[:call_id] || data["call_id"],
      model: model
    })

    # Relay text step start to parent conversation if this is a sub-agent
    maybe_relay_turn_started(conversation_id, turn_id, model)

    {:ok, :continue}
  end

  defp handle_llm_turn_completed(signal, conversation_id) do
    data = signal.data || %{}
    turn_type = normalize_turn_type(data[:turn_type] || data["turn_type"])
    turn_id = data[:turn_id] || data["turn_id"]

    Signals.turn_completed(conversation_id, %{
      request_id: data[:request_id] || data["request_id"],
      turn_id: turn_id,
      iteration: data[:iteration] || data["iteration"],
      call_id: data[:call_id] || data["call_id"],
      turn_type: turn_type
    })

    if turn_type == :tool_calls do
      Signals.state_change(conversation_id, :running_tools)
    end

    # Complete the text step on the parent card
    maybe_relay_turn_completed(conversation_id, turn_id)

    {:ok, :continue}
  end

  # ============================================================================
  # Parent Relay (child text streaming → parent tool steps)
  # ============================================================================

  defp maybe_relay_turn_started(conversation_id, turn_id, model) do
    case RunRelay.find_parent(conversation_id) do
      {source_conversation_id, source_event_id} ->
        step_id = text_step_id(source_event_id, turn_id)
        label = if model, do: "Responding (#{format_model(model)})...", else: "Responding..."

        Signals.relay_tool_step_start(
          source_conversation_id,
          source_event_id,
          step_id,
          0,
          label,
          %{type: :text}
        )

      nil ->
        :ok
    end
  end

  defp maybe_relay_text_delta(conversation_id, delta) do
    case RunRelay.find_parent(conversation_id) do
      {source_conversation_id, source_event_id} ->
        # Use a stable step_id based on the current turn stored in process dict
        step_id = current_text_step_id(source_event_id)

        if step_id do
          Signals.relay_tool_step_progress(
            source_conversation_id,
            source_event_id,
            step_id,
            delta
          )
        end

      nil ->
        :ok
    end
  end

  defp maybe_relay_turn_completed(conversation_id, turn_id) do
    case RunRelay.find_parent(conversation_id) do
      {source_conversation_id, source_event_id} ->
        step_id = text_step_id(source_event_id, turn_id)

        Signals.relay_tool_step_complete(
          source_conversation_id,
          source_event_id,
          step_id,
          :complete
        )

        # Clear the current turn step_id
        Process.delete(:relay_current_text_step_id)

      nil ->
        :ok
    end
  end

  defp text_step_id(source_event_id, turn_id) do
    step_id = "#{source_event_id}-step-text-#{turn_id}"
    # Store in process dict so delta relay can use it without needing turn_id
    Process.put(:relay_current_text_step_id, step_id)
    step_id
  end

  defp current_text_step_id(source_event_id) do
    Process.get(:relay_current_text_step_id) ||
      "#{source_event_id}-step-text-current"
  end

  defp format_model(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, name] -> name
      _ -> model
    end
  end

  defp format_model(model), do: inspect(model)

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_turn_type(value) when is_atom(value), do: value

  defp normalize_turn_type(value) when is_binary(value) do
    case value do
      "tool_calls" -> :tool_calls
      "final_answer" -> :final_answer
      _ -> :final_answer
    end
  end

  defp normalize_turn_type(_), do: :final_answer
end
