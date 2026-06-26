defmodule Magus.Telemetry do
  @moduledoc """
  Telemetry event helpers for the Magus application.

  This module provides convenient functions for emitting telemetry events
  from various parts of the application. All events follow the naming
  convention `[:magus, :domain, :event]`.

  ## Usage

      # Emit an agent started event
      Magus.Telemetry.agent_started(:conversation, "conv:abc-123")

      # Measure tool execution time
      Magus.Telemetry.span(:tool, %{tool: "web_search"}, fn ->
        execute_tool(params)
      end)

  ## Event Categories

  - **agents** - Agent lifecycle events (started, hibernated, thawed)
  - **llm** - LLM streaming and token events
  - **integrations** - Webhook and operation events
  - **memory** - Context loading and extraction events
  - **reactor** - Reactor execution events
  """

  require Logger

  # =============================================================================
  # Agent Events
  # =============================================================================

  @doc """
  Emits an event when an agent is started.
  """
  @spec agent_started(:conversation | :memory | :input, String.t()) :: :ok
  def agent_started(type, agent_id) do
    :telemetry.execute(
      [:magus, :agents, :started],
      %{count: 1},
      %{type: type, agent_id: agent_id}
    )
  end

  @doc """
  Emits an event when an agent is hibernated to PostgreSQL.
  """
  @spec agent_hibernated(:conversation | :memory | :input, String.t()) :: :ok
  def agent_hibernated(type, agent_id) do
    :telemetry.execute(
      [:magus, :agents, :hibernated],
      %{count: 1},
      %{type: type, agent_id: agent_id}
    )
  end

  @doc """
  Emits an event when an agent is thawed from hibernation.
  """
  @spec agent_thawed(:conversation | :memory | :input, String.t()) :: :ok
  def agent_thawed(type, agent_id) do
    :telemetry.execute(
      [:magus, :agents, :thawed],
      %{count: 1},
      %{type: type, agent_id: agent_id}
    )
  end

  @doc """
  Emits a tool execution event with duration and success status.
  """
  @spec tool_executed(String.t(), pos_integer(), boolean()) :: :ok
  def tool_executed(tool_name, duration_ms, success?) do
    :telemetry.execute(
      [:magus, :agents, :tool],
      %{duration: duration_ms, count: 1},
      %{tool: tool_name, success: success?}
    )
  end

  @doc """
  Emits an event when memory context request times out.
  """
  @spec memory_context_timeout(String.t()) :: :ok
  def memory_context_timeout(user_id) do
    :telemetry.execute(
      [:magus, :agents, :memory_timeout],
      %{count: 1},
      %{user_id: user_id}
    )
  end

  # =============================================================================
  # LLM Events
  # =============================================================================

  @doc """
  Emits an LLM streaming completion event.
  """
  @spec llm_stream_complete(String.t(), atom(), pos_integer(), boolean()) :: :ok
  def llm_stream_complete(model, mode, duration_ms, success?) do
    :telemetry.execute(
      [:magus, :llm, :stream],
      %{duration: duration_ms},
      %{model: model, mode: mode, success: success?}
    )

    :telemetry.execute(
      [:magus, :llm, :request],
      %{count: 1},
      %{model: model, mode: mode, success: success?}
    )
  end

  @doc """
  Emits LLM token usage.
  """
  @spec llm_tokens(String.t(), pos_integer(), pos_integer()) :: :ok
  def llm_tokens(model, input_tokens, output_tokens) do
    :telemetry.execute(
      [:magus, :llm, :tokens],
      %{input: input_tokens, output: output_tokens},
      %{model: model}
    )
  end

  @doc """
  Emits a per-turn LLM call event for an agent's ReAct loop.

  Measurements: `:duration` (ms total wall-clock), `:ttft` (ms to first streamed
  token; absent for non-streaming calls), `:prompt_tokens`, `:completion_tokens`,
  `:total_tokens`, `:empty_retries` (blank-answer re-asks before this result).

  Metadata: `:model`, `:finish_reason` (`"stop" | "tool_calls" | "empty" |
  "timeout" | ...`), `:empty?` (true when the final answer was blank), `:streaming`,
  `:success`, `:request_id`, `:run_id`.

  Surfaced in the LiveDashboard at `/admin/telemetry` via metrics registered in
  `MagusWeb.Telemetry`.
  """
  @spec llm_call(map(), map()) :: :ok
  def llm_call(measurements, metadata) when is_map(measurements) and is_map(metadata) do
    :telemetry.execute([:magus, :agents, :llm, :call], measurements, metadata)
  end

  # =============================================================================
  # Integration Events
  # =============================================================================

  @doc """
  Emits a webhook received event.
  """
  @spec webhook_received(atom(), :success | :error | :rate_limited) :: :ok
  def webhook_received(provider, status) do
    :telemetry.execute(
      [:magus, :integrations, :webhook],
      %{count: 1},
      %{provider: provider, status: status}
    )
  end

  @doc """
  Emits a rate limited event.
  """
  @spec rate_limited(atom(), atom()) :: :ok
  def rate_limited(provider, operation) do
    :telemetry.execute(
      [:magus, :integrations, :rate_limited],
      %{count: 1},
      %{provider: provider, operation: operation}
    )
  end

  @doc """
  Emits an integration operation event.
  """
  @spec integration_operation(atom(), atom(), pos_integer(), boolean()) :: :ok
  def integration_operation(provider, operation, duration_ms, success?) do
    :telemetry.execute(
      [:magus, :integrations, :operation],
      %{duration: duration_ms},
      %{provider: provider, operation: operation, success: success?}
    )
  end

  # =============================================================================
  # Memory Events
  # =============================================================================

  @doc """
  Emits a memory context load event.
  """
  @spec memory_context_loaded(pos_integer()) :: :ok
  def memory_context_loaded(duration_ms) do
    :telemetry.execute(
      [:magus, :memory, :context],
      %{duration: duration_ms},
      %{}
    )
  end

  @doc """
  Emits a memory extraction event.
  """
  @spec memory_extracted(:local | :user, pos_integer()) :: :ok
  def memory_extracted(scope, count) do
    :telemetry.execute(
      [:magus, :memory, :extraction],
      %{count: count},
      %{scope: scope}
    )
  end

  @doc """
  Emits a memory search event.
  """
  @spec memory_searched(:local | :user | :all) :: :ok
  def memory_searched(scope) do
    :telemetry.execute(
      [:magus, :memory, :search],
      %{count: 1},
      %{scope: scope}
    )
  end

  # =============================================================================
  # Reactor Events
  # =============================================================================

  @doc """
  Emits a reactor execution event.
  """
  @spec reactor_executed(atom() | String.t(), pos_integer(), boolean()) :: :ok
  def reactor_executed(reactor_name, duration_ms, success?) do
    # Keep the tag as a string rather than minting an atom per reactor name
    # (atom-exhaustion safety; this is the sole emitter of [:magus, :reactor]).
    name =
      case reactor_name do
        atom when is_atom(atom) -> atom |> Module.split() |> List.last()
        string when is_binary(string) -> string
      end

    :telemetry.execute(
      [:magus, :reactor],
      %{duration: duration_ms, count: 1},
      %{reactor: name, success: success?}
    )
  end

  # =============================================================================
  # Generic Span Helper
  # =============================================================================

  @doc """
  Measures the execution time of a function and emits a telemetry event.

  ## Examples

      Magus.Telemetry.span(:tool, %{tool: "web_search"}, fn ->
        {:ok, results} = execute_search(query)
        {:ok, results}
      end)

  Returns the result of the function.
  """
  @spec span(atom(), map(), (-> result)) :: result when result: term()
  def span(event_type, metadata, fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      emit_span_event(event_type, duration_ms, metadata, true)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        emit_span_event(event_type, duration_ms, metadata, false)
        reraise e, __STACKTRACE__
    end
  end

  defp emit_span_event(:tool, duration_ms, %{tool: tool_name}, success?) do
    tool_executed(tool_name, duration_ms, success?)
  end

  defp emit_span_event(:llm, duration_ms, %{model: model, mode: mode}, success?) do
    llm_stream_complete(model, mode, duration_ms, success?)
  end

  defp emit_span_event(:reactor, duration_ms, %{reactor: name}, success?) do
    reactor_executed(name, duration_ms, success?)
  end

  defp emit_span_event(:memory_context, duration_ms, _metadata, _success?) do
    memory_context_loaded(duration_ms)
  end

  defp emit_span_event(:integration, duration_ms, %{provider: p, operation: o}, success?) do
    integration_operation(p, o, duration_ms, success?)
  end

  defp emit_span_event(event_type, duration_ms, metadata, success?) do
    # Generic fallback for custom event types
    :telemetry.execute(
      [:magus, event_type],
      %{duration: duration_ms},
      Map.put(metadata, :success, success?)
    )
  end
end
