defmodule Magus.Agents.Signals do
  @moduledoc """
  PubSub broadcast helpers for the agent system.

  Provides direct PubSub broadcasts for real-time streaming events:
  - Text streaming (chunks, completion, thinking)
  - State changes and response lifecycle
  - Tool execution events (start, progress, complete)
  - Tool sub-step events for hierarchical progress
  """

  require Logger

  # ============================================================================
  # Direct PubSub Broadcasts (Real-time Critical)
  # ============================================================================

  @doc """
  Broadcast text chunk to conversation PubSub topic.

  Used during LLM streaming for real-time character-by-character display.
  """
  def text_chunk(conversation_id, message_id, text, delta, opts \\ []) do
    payload =
      %{
        type: "text.chunk",
        message_id: message_id,
        text: text,
        delta: delta
      }
      |> maybe_put(:custom_agent_id, opts[:custom_agent_id])
      |> maybe_put(:custom_agent_name, opts[:custom_agent_name])

    broadcast(conversation_id, payload)
  end

  @doc """
  Broadcast text completion with usage stats.

  Marks the end of LLM streaming for an iteration.
  """
  def text_complete(conversation_id, message_id, text, usage, opts \\ []) do
    payload =
      %{
        type: "text.complete",
        message_id: message_id,
        text: text,
        usage: usage
      }
      |> maybe_put(:custom_agent_id, opts[:custom_agent_id])
      |> maybe_put(:custom_agent_name, opts[:custom_agent_name])

    broadcast(conversation_id, payload)
  end

  @doc """
  Broadcast that an LLM turn produced no persistable content.

  Emitted when the model returns a blank final answer (no text, no tool calls,
  no attachments) so the turn is dropped instead of persisted. Gives the UI and
  any observers an explicit, traceable signal in place of the previous silent
  empty `text.complete` bubble.
  """
  def turn_empty(conversation_id, message_id, request_id) do
    broadcast(conversation_id, %{
      type: "turn.empty",
      message_id: message_id,
      request_id: request_id
    })
  end

  @doc """
  Broadcast thinking chunk to conversation PubSub topic.

  Used during LLM streaming for real-time display of model reasoning/thinking.
  Models like Gemini emit thinking content separately from regular content.
  """
  def thinking_chunk(conversation_id, message_id, text, delta) do
    broadcast(conversation_id, %{
      type: "thinking.chunk",
      message_id: message_id,
      text: text,
      delta: delta
    })
  end

  @doc """
  Broadcast conversation state change.

  Updates the thinking/processing status in the UI.
  """
  def state_change(conversation_id, state) do
    broadcast(conversation_id, %{
      type: "state.change",
      state: state
    })
  end

  @doc """
  Broadcast response completion to the conversation.

  Signals that the full agent response cycle is done (all iterations complete).
  The UI uses this to reset all streaming/thinking state and refresh usage limits.
  """
  def response_complete(conversation_id, payload \\ %{}) do
    broadcast(conversation_id, Map.put(payload, :type, "response.complete"))
  end

  @doc """
  Broadcast the latest context-window snapshot to the conversation.

  Used by the `ContextPlugin` to push token-usage / context stats to the UI so
  the chat view can render the current context-window state. The `snapshot` map
  is forwarded as-is with a `:type` of `"context.updated"`.
  """
  def context_updated(conversation_id, snapshot) when is_map(snapshot) do
    broadcast(conversation_id, Map.put(snapshot, :type, "context.updated"))
  end

  @doc """
  Broadcast start of an LLM turn.
  """
  def turn_started(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "turn.started"))
  end

  @doc """
  Broadcast completion of an LLM turn.
  """
  def turn_completed(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "turn.completed"))
  end

  @doc """
  Broadcast that an agent run started.
  """
  def run_started(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "run.started"))
  end

  @doc """
  Broadcast progress updates for an agent run.
  """
  def run_progress(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "run.progress"))
  end

  @doc """
  Broadcast successful completion of an agent run.
  """
  def run_completed(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "run.completed"))
  end

  @doc """
  Broadcast failed completion of an agent run.
  """
  def run_failed(conversation_id, payload) when is_map(payload) do
    broadcast(conversation_id, Map.put(payload, :type, "run.failed"))
  end

  @doc """
  Broadcast an error event to the conversation.

  Used to notify the UI of errors that occur during agent processing,
  such as failures to start the agent or LLM errors.
  """
  def error(conversation_id, message_id, error_type, error_message) do
    broadcast(conversation_id, %{
      type: "error",
      message_id: message_id,
      error_type: error_type,
      error_message: error_message
    })
  end

  @doc """
  Broadcast tool start event.

  Signals the beginning of tool execution with inputs.
  """
  def broadcast_tool_start(conversation_id, event_id, tool_name, display_name, inputs) do
    broadcast(conversation_id, %{
      type: "tool.start",
      event_id: event_id,
      tool_name: tool_name,
      display_name: display_name,
      inputs: inputs
    })
  end

  @doc """
  Broadcast tool progress event.

  Signals incremental progress during tool execution.
  """
  def broadcast_tool_progress(conversation_id, event_id, tool_name, progress_type, data) do
    broadcast(conversation_id, %{
      type: "tool.progress",
      event_id: event_id,
      tool_name: tool_name,
      progress_type: progress_type,
      data: data
    })
  end

  @doc """
  Broadcast tool completion event.

  Signals completion of tool execution with result or error.
  """
  def broadcast_tool_complete(
        conversation_id,
        event_id,
        tool_name,
        status,
        summary,
        duration_ms,
        error
      ) do
    broadcast(conversation_id, %{
      type: "tool.complete",
      event_id: event_id,
      tool_name: tool_name,
      status: status,
      output_summary: summary,
      duration_ms: duration_ms,
      error: error
    })
  end

  # ============================================================================
  # Tool Sub-Step Broadcasts
  # ============================================================================

  @doc """
  Broadcast tool step start event.

  Signals the beginning of a sub-step within a tool execution.
  Steps provide hierarchical progress (tool → steps → streaming content).
  """
  def tool_step_start(
        conversation_id,
        event_id,
        step_id,
        step_index,
        label,
        data \\ %{},
        tool_name \\ nil
      ) do
    payload = %{
      type: "tool.step.start",
      event_id: event_id,
      step_id: step_id,
      step_index: step_index,
      label: label,
      data: data
    }

    payload = if tool_name, do: Map.put(payload, :tool_name, tool_name), else: payload
    broadcast(conversation_id, payload)
  end

  @doc """
  Broadcast tool step progress event.

  Streams content into a specific sub-step. Supports `:append` (default) and `:replace` modes.
  """
  def tool_step_progress(conversation_id, event_id, step_id, content, mode \\ :append) do
    broadcast(conversation_id, %{
      type: "tool.step.progress",
      event_id: event_id,
      step_id: step_id,
      content: content,
      mode: mode
    })
  end

  @doc """
  Broadcast tool step completion event.

  Marks a sub-step as complete with an optional summary.
  """
  def tool_step_complete(conversation_id, event_id, step_id, status \\ :complete, summary \\ nil) do
    broadcast(conversation_id, %{
      type: "tool.step.complete",
      event_id: event_id,
      step_id: step_id,
      status: status,
      summary: summary
    })
  end

  # ============================================================================
  # UI Hints (tool-initiated pane requests)
  # ============================================================================

  @doc """
  Request the LiveView to open the Brain pane on a specific page.

  Broadcast by brain-editing tools after creating a new page so the user can
  watch content unfold live. Workbench `ConversationView` intercepts this
  signal in its `handle_info/2` to open the brain companion tab.
  """
  def open_brain_pane(conversation_id, brain_id, page_id) do
    broadcast(conversation_id, %{
      type: "ui.open_brain_pane",
      brain_id: brain_id,
      page_id: page_id
    })
  end

  # ============================================================================
  # Cross-Conversation Relay (child → parent tool steps)
  # ============================================================================

  @doc """
  Relay a child tool event as a step to a parent conversation's tool card.

  Used by ToolEventPlugin to broadcast child tool.start as tool.step.start
  on the parent conversation, keyed to the parent's spawn_sub_agent event_id.
  """
  def relay_tool_step_start(
        parent_conversation_id,
        source_event_id,
        step_id,
        step_index,
        label,
        data \\ %{}
      ) do
    tool_step_start(parent_conversation_id, source_event_id, step_id, step_index, label, data)
  end

  @doc """
  Relay a child tool completion as a step completion to a parent conversation's tool card.
  """
  def relay_tool_step_complete(
        parent_conversation_id,
        source_event_id,
        step_id,
        status \\ :complete,
        summary \\ nil
      ) do
    tool_step_complete(parent_conversation_id, source_event_id, step_id, status, summary)
  end

  @doc """
  Relay streaming content as step progress to a parent conversation's tool card.

  Used by StreamingPlugin to stream child agent text responses into a step
  on the parent's spawn_sub_agent card.
  """
  def relay_tool_step_progress(
        parent_conversation_id,
        source_event_id,
        step_id,
        content,
        mode \\ :append
      ) do
    tool_step_progress(parent_conversation_id, source_event_id, step_id, content, mode)
  end

  # ============================================================================
  # Tool Progress / Step Helpers
  # ============================================================================

  @doc """
  Emit a tool progress event from within a tool's run/2 function.
  """
  def emit_tool_progress(context, progress_type, data \\ %{}) when is_map(context) do
    with {:ok, conversation_id} <- get_context_field(context, :__conversation_id__),
         {:ok, raw_event_id} <- get_context_field(context, :__event_id__),
         {:ok, tool_name} <- get_context_field(context, :__tool_name__) do
      event_id = normalize_tool_event_id(raw_event_id)
      broadcast_tool_progress(conversation_id, event_id, tool_name, progress_type, data)
      :ok
    else
      :error ->
        Logger.warning("Cannot emit tool progress: missing event metadata in context")
        :error
    end
  end

  @doc """
  Emit a tool step start event from within a tool's run/2 function.

  Creates a new sub-step within the current tool execution.

  ## Example

      def run(params, context) do
        Signals.emit_tool_step_start(context, 0, "Searching web")
        results = search(params.query)
        Signals.emit_tool_step_complete(context, 0)
        {:ok, %{results: results}}
      end
  """
  def emit_tool_step_start(context, step_index, label, data \\ %{}) when is_map(context) do
    with {:ok, conversation_id} <- get_context_field(context, :__conversation_id__),
         {:ok, raw_event_id} <- get_context_field(context, :__event_id__),
         {:ok, tool_name} <- get_context_field(context, :__tool_name__) do
      event_id = normalize_tool_event_id(raw_event_id)
      step_id = "#{event_id}-step-#{step_index}"

      signal_agent(conversation_id, "ai.tool.step.started", %{
        event_id: event_id,
        step_id: step_id,
        step_index: step_index,
        label: label,
        data: data,
        tool_name: tool_name
      })

      {:ok, step_id}
    else
      :error ->
        Logger.warning("Cannot emit tool step start: missing event metadata in context")
        :error
    end
  end

  @doc """
  Emit a tool step progress event from within a tool's run/2 function.

  Streams content into a sub-step. Use `:append` (default) to accumulate or `:replace` to overwrite.
  """
  def emit_tool_step_progress(context, step_index, content, mode \\ :append)
      when is_map(context) do
    with {:ok, conversation_id} <- get_context_field(context, :__conversation_id__),
         {:ok, raw_event_id} <- get_context_field(context, :__event_id__) do
      event_id = normalize_tool_event_id(raw_event_id)
      step_id = "#{event_id}-step-#{step_index}"

      signal_agent(conversation_id, "ai.tool.step.progress", %{
        event_id: event_id,
        step_id: step_id,
        content: content,
        mode: mode
      })

      :ok
    else
      :error ->
        Logger.warning("Cannot emit tool step progress: missing event metadata in context")
        :error
    end
  end

  @doc """
  Emit a tool step complete event from within a tool's run/2 function.
  """
  def emit_tool_step_complete(context, step_index, status \\ :complete, summary \\ nil)
      when is_map(context) do
    with {:ok, conversation_id} <- get_context_field(context, :__conversation_id__),
         {:ok, raw_event_id} <- get_context_field(context, :__event_id__) do
      event_id = normalize_tool_event_id(raw_event_id)
      step_id = "#{event_id}-step-#{step_index}"

      signal_agent(conversation_id, "ai.tool.step.complete", %{
        event_id: event_id,
        step_id: step_id,
        status: status,
        summary: summary
      })

      :ok
    else
      :error ->
        Logger.warning("Cannot emit tool step complete: missing event metadata in context")
        :error
    end
  end

  defp get_context_field(context, key) do
    case Map.get(context, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Send a signal to the conversation agent GenServer. Routes through the agent's
  # plugin pipeline so step events are serialized with tool.start/tool.complete,
  # guaranteeing correct event ordering at the LiveView.
  defp signal_agent(conversation_id, signal_type, data) do
    agent_id = "conv:#{conversation_id}"

    try do
      case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
        {:ok, pid} ->
          signal = Jido.Signal.new!(signal_type, data)
          Jido.AgentServer.cast(pid, signal)

        :error ->
          # Agent not running; fall back to direct broadcast
          Logger.warning("Agent #{agent_id} not found for step event, broadcasting directly")
          broadcast(conversation_id, Map.put(data, :type, signal_type_to_pubsub(signal_type)))
      end
    rescue
      ArgumentError ->
        # Registry not started (e.g. test environment); fall back to direct broadcast
        broadcast(conversation_id, Map.put(data, :type, signal_type_to_pubsub(signal_type)))
    end
  end

  defp signal_type_to_pubsub("ai.tool.step.started"), do: "tool.step.start"
  defp signal_type_to_pubsub("ai.tool.step.progress"), do: "tool.step.progress"
  defp signal_type_to_pubsub("ai.tool.step.complete"), do: "tool.step.complete"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_tool_event_id(event_id) when is_binary(event_id) do
    cond do
      event_id == "" ->
        event_id

      valid_uuid?(event_id) ->
        event_id

      tool_call_id?(event_id) ->
        deterministic_tool_event_id(event_id)

      true ->
        event_id
    end
  end

  defp normalize_tool_event_id(event_id), do: event_id

  defp tool_call_id?(event_id) do
    String.starts_with?(event_id, "call_") or
      String.starts_with?(event_id, "call-") or
      String.starts_with?(event_id, "tool-call-")
  end

  defp deterministic_tool_event_id(call_id) do
    hash = :crypto.hash(:md5, "magus:tool_event:#{call_id}")
    <<a::48, _::4, b::12, _::2, c::62>> = hash

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
      "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
    end)
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  defp broadcast(conversation_id, payload) do
    # Use Magus.Endpoint.broadcast to ensure messages are wrapped in
    # Phoenix.Socket.Broadcast struct, matching how handle_info expects them
    Magus.Endpoint.broadcast(topic(conversation_id), "agent_signal", payload)
  end

  defp topic(conversation_id) do
    "agents:#{conversation_id}"
  end
end
