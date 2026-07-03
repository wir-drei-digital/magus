defmodule Magus.Agents.Plugins.ToolEventPlugin do
  @moduledoc """
  Plugin that handles tool lifecycle events for conversation agents.

  Translates ReAct tool signals into PubSub broadcasts and persists tool results:

  | ReAct Signal        | Magus PubSub Event | Persisted? | Return Value                |
  |---------------------|---------------------|------------|-----------------------------|
  | `ai.tool.started`   | `tool.start`        | No         | `{:ok, {:override, Noop}}`  |
  | `ai.tool.result`    | `tool.complete`     | Yes        | `{:ok, :continue}`          |

  This is one of several focused plugins extracted from the monolithic conversation skill.
  It handles ONLY tool lifecycle events -- no streaming, no inbound transformation, no
  request lifecycle.

  ## Support Modules

  - `Helpers` -- state extraction and formatting utilities (tool_event_id_for_call_id)
  - `Persistence` -- broadcast_and_persist_tool_result for DB writes + PubSub
  """

  use Jido.Plugin,
    name: "tool_events",
    state_key: :tool_events,
    actions: [],
    description: "Tool lifecycle event broadcasting and persistence",
    category: "magus",
    tags: ["conversation", "tools", "signal-translation"],
    signal_patterns: [
      "ai.tool.started",
      "ai.tool.result",
      "ai.tool.step.started",
      "ai.tool.step.progress",
      "ai.tool.step.complete"
    ]

  require Logger

  alias Magus.Agents.Plugins.Support.{AttachmentStash, Helpers, Persistence, RunRelay}
  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.ToolBuilder

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

    if signal.type in ["ai.tool.started", "ai.tool.result"] do
      Magus.Agents.RunLiveness.touch(conversation_id)
    end

    case signal.type do
      "ai.tool.started" ->
        handle_tool_started(signal, conversation_id)

      "ai.tool.result" ->
        handle_tool_result(signal, agent, conversation_id)

      "ai.tool.step." <> _ ->
        handle_tool_step(signal, conversation_id)

      _ ->
        Logger.debug("[ToolEventPlugin] Unhandled signal: #{signal.type}")
        {:ok, :continue}
    end
  end

  # ============================================================================
  # Tool Signal Handlers
  # ============================================================================

  defp handle_tool_started(signal, conversation_id) do
    data = signal.data || %{}
    tool_name = data[:tool_name] || data["tool_name"] || "unknown"
    call_id = data[:call_id] || data["call_id"] || ""
    event_id = Helpers.tool_event_id_for_call_id(call_id)
    inputs = data[:arguments] || data["arguments"] || %{}
    display_name = resolve_tool_display_name(tool_name)

    Signals.state_change(conversation_id, :running_tools)

    # Broadcast tool.start first so the LiveView creates the tracker entry
    Signals.broadcast_tool_start(
      conversation_id,
      event_id,
      tool_name,
      display_name,
      inputs
    )

    # Mark this event_id as started, then replay any buffered step events
    # that arrived before tool_started (due to the shorter direct signal path).
    mark_tool_started(event_id)
    replay_buffered_steps(event_id, conversation_id)

    maybe_relay_step_start(conversation_id, event_id, tool_name, display_name)

    {:ok, {:override, Jido.Actions.Control.Noop}}
  end

  defp handle_tool_result(signal, agent, conversation_id) do
    data = signal.data || %{}
    tool_name = data[:tool_name] || data["tool_name"] || "unknown"
    call_id = data[:call_id] || data["call_id"] || ""
    raw_result = data[:result] || data["result"]
    event_id = Helpers.tool_event_id_for_call_id(call_id)

    {result, attachments} = pop_internal_attachments(raw_result)
    AttachmentStash.put(attachments)

    summary = extract_relay_summary(tool_name, raw_result)

    Persistence.broadcast_and_persist_tool_result(
      conversation_id,
      call_id,
      tool_name,
      result,
      summary: summary
    )

    maybe_track_feature_usage(agent, tool_name)

    maybe_relay_step_complete(conversation_id, event_id, summary)

    # Clean up buffering state and switch back to model-thinking state.
    cleanup_tool_event_state(event_id)
    Signals.state_change(conversation_id, :thinking)

    {:ok, :continue}
  end

  # Extract file IDs from a tool result's :__attachments__ key so plugins can
  # attach them to the assistant's response message. Returns a stripped result
  # and the list of file IDs (or [] when absent).
  defp pop_internal_attachments({:ok, %{__attachments__: ids} = result})
       when is_list(ids) do
    {{:ok, Map.drop(result, [:__attachments__])}, ids}
  end

  defp pop_internal_attachments(other), do: {other, []}

  # ============================================================================
  # Tool Step Handlers (routed through agent for event ordering)
  # ============================================================================

  defp handle_tool_step(signal, conversation_id) do
    data = signal.data || %{}
    event_id = data[:event_id]

    pubsub_type =
      case signal.type do
        "ai.tool.step.started" -> "tool.step.start"
        "ai.tool.step.progress" -> "tool.step.progress"
        "ai.tool.step.complete" -> "tool.step.complete"
      end

    payload = Map.put(data, :type, pubsub_type)

    if tool_started?(event_id) do
      # tool.start already broadcast; send step immediately
      broadcast_step(conversation_id, payload)
    else
      # tool.start hasn't arrived yet; buffer for replay
      buffer_step_event(event_id, {conversation_id, payload})
    end

    {:ok, {:override, Jido.Actions.Control.Noop}}
  end

  defp broadcast_step(conversation_id, payload) do
    Magus.Endpoint.broadcast(
      "agents:#{conversation_id}",
      "agent_signal",
      payload
    )
  end

  # ============================================================================
  # Step Event Buffer (process dictionary, safe in agent GenServer)
  #
  # Step events can arrive before tool_started because the tool signals the
  # agent directly while tool_started takes a longer path through the runner's
  # event stream. We buffer early steps and replay them after tool.start.
  # ============================================================================

  defp mark_tool_started(event_id) do
    Process.put({:tool_started, event_id}, true)
  end

  defp tool_started?(event_id) do
    Process.get({:tool_started, event_id}, false)
  end

  defp buffer_step_event(event_id, event) do
    key = {:tool_step_buffer, event_id}
    Process.put(key, [event | Process.get(key, [])])
  end

  defp replay_buffered_steps(event_id, _conversation_id) do
    key = {:tool_step_buffer, event_id}

    for {conv_id, payload} <- Enum.reverse(Process.get(key, [])) do
      broadcast_step(conv_id, payload)
    end

    Process.delete(key)
  end

  defp cleanup_tool_event_state(event_id) do
    Process.delete({:tool_started, event_id})
    Process.delete({:tool_step_buffer, event_id})
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_track_feature_usage(agent, tool_name) do
    user_id = agent.state[:user_id]

    if user_id do
      case tool_name do
        "web_search" -> Magus.FeatureUsage.track(user_id, "web_search", "execute")
        "create_job" -> Magus.FeatureUsage.track(user_id, "reminders", "create")
        "spawn_sub_agent" -> Magus.FeatureUsage.track(user_id, "council", "execute")
        "run_code" -> Magus.FeatureUsage.track(user_id, "sandbox", "execute")
        "create_task" -> Magus.FeatureUsage.track(user_id, "tasks", "create")
        "create_thread" -> Magus.FeatureUsage.track(user_id, "threads", "create")
        _ -> :ok
      end
    end
  end

  defp resolve_tool_display_name(tool_name) when is_binary(tool_name) do
    module = ToolBuilder.skill_tool_mapping()[tool_name]

    cond do
      is_atom(module) and function_exported?(module, :display_name, 0) ->
        module.display_name()

      true ->
        tool_name
    end
  end

  # ============================================================================
  # Parent Relay (child tool events -> parent tool.step events)
  # ============================================================================

  defp maybe_relay_step_start(child_conversation_id, child_event_id, tool_name, display_name) do
    case RunRelay.find_parent(child_conversation_id) do
      {source_conversation_id, source_event_id} ->
        step_id = "#{source_event_id}-step-#{child_event_id}"

        Signals.relay_tool_step_start(
          source_conversation_id,
          source_event_id,
          step_id,
          0,
          display_name || tool_name
        )

      nil ->
        :ok
    end
  end

  defp maybe_relay_step_complete(child_conversation_id, child_event_id, summary) do
    case RunRelay.find_parent(child_conversation_id) do
      {source_conversation_id, source_event_id} ->
        step_id = "#{source_event_id}-step-#{child_event_id}"

        Signals.relay_tool_step_complete(
          source_conversation_id,
          source_event_id,
          step_id,
          :complete,
          summary
        )

      nil ->
        :ok
    end
  end

  defp extract_relay_summary(tool_name, {:ok, result}) when is_map(result) do
    module = ToolBuilder.skill_tool_mapping()[tool_name]

    if is_atom(module) and function_exported?(module, :summarize_output, 1) do
      module.summarize_output(result)
    else
      "Completed"
    end
  end

  defp extract_relay_summary(_tool_name, _result), do: "Completed"
end
