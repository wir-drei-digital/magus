defmodule Magus.Agents.Strategies.ReactStrategy do
  @moduledoc """
  ReAct strategy delegated to an internal per-parent worker agent.

  The parent strategy remains the public orchestration boundary (`ask/await/ask_sync`),
  while runtime execution is delegated to a lazily spawned child worker tagged
  `:react_worker`.

  ## Delegation Model

  1. Parent receives `"ai.react.query"` and prepares runtime config/context.
  2. Parent lazily spawns internal worker on first request (if needed).
  3. Parent emits `"ai.react.worker.start"` to worker.
  4. Worker streams `Jido.AI.Reasoning.ReAct` events and emits `"ai.react.worker.event"` to parent.
  5. Parent applies runtime events to parent state and emits external lifecycle/LLM/tool signals.

  ## Worker Lifecycle

  - Child tag is fixed as `:react_worker`.
  - Single active run is enforced (`:reject` busy policy).
  - Worker crash during active request marks the request failed.
  - No machine-driven fallback path is retained.

  ## Trace Retention

  Parent stores per-request runtime event history in `request_traces` with a hard cap:

      %{request_id => %{events: [event, ...], truncated?: boolean()}}

  Once 2000 events are stored for a request, `truncated?` is set to `true`
  and new events are not appended.
  """

  use Jido.Agent.Strategy

  require Logger

  alias Jido.Agent
  alias Jido.Agent.Directive, as: AgentDirective
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AI.Directive
  alias Jido.AI.Reasoning.ReAct.Config, as: ReActRuntimeConfig
  alias Jido.AI.Signal
  alias Jido.AI.Reasoning.Helpers
  alias Jido.AI.Thread
  alias Jido.AI.ToolAdapter
  alias Jido.AI.Turn
  alias Jido.Signal, as: CoreSignal
  alias Magus.Agents.Context.ContextReport
  alias Magus.Agents.Support.ToolCallText

  @type config :: %{
          tools: [module()],
          reqllm_tools: [ReqLLM.Tool.t()],
          actions_by_name: %{String.t() => module()},
          system_prompt: String.t(),
          model: String.t(),
          max_iterations: pos_integer(),
          streaming: boolean(),
          base_tool_context: map(),
          base_req_http_options: list(),
          base_llm_opts: keyword(),
          provider_opt_keys_by_string: %{optional(String.t()) => atom()},
          request_policy: :reject,
          tool_timeout_ms: pos_integer(),
          tool_max_retries: non_neg_integer(),
          tool_retry_backoff_ms: non_neg_integer(),
          observability: map(),
          runtime_adapter: true,
          runtime_task_supervisor: pid() | atom() | nil,
          agent_id: String.t() | nil
        }

  @default_model :fast
  @request_trace_cap 2000
  @worker_tag :react_worker
  @source "/magus/ai/react/strategy"
  @reqllm_generation_opt_keys_by_string ReqLLM.Provider.Options.all_generation_keys()
                                        |> Enum.map(&{Atom.to_string(&1), &1})
                                        |> Map.new()
  @reserved_llm_opt_keys [:tools]

  @default_system_prompt """
  You are a helpful AI assistant using the ReAct (Reason-Act) pattern.
  When you need to perform an action, use the available tools.
  When you have enough information to answer, provide your final answer directly.
  Think step by step and explain your reasoning.
  """

  @start :ai_react_start
  @llm_result :ai_react_llm_result
  @tool_result :ai_react_tool_result
  @llm_partial :ai_react_llm_partial
  @cancel :ai_react_cancel
  @steer :ai_react_steer
  @request_error :ai_react_request_error
  @register_tool :ai_react_register_tool
  @unregister_tool :ai_react_unregister_tool
  @set_tool_context :ai_react_set_tool_context
  @set_system_prompt :ai_react_set_system_prompt
  @runtime_event :ai_react_runtime_event
  @worker_event :ai_react_worker_event
  @worker_child_started :ai_react_worker_child_started
  @worker_child_exit :ai_react_worker_child_exit

  @doc "Returns the action atom for starting a ReAct conversation."
  @spec start_action() :: :ai_react_start
  def start_action, do: @start

  @doc "Returns the legacy action atom for handling LLM results (no-op in delegated mode)."
  @spec llm_result_action() :: :ai_react_llm_result
  def llm_result_action, do: @llm_result

  @doc "Returns the action atom for registering a tool dynamically."
  @spec register_tool_action() :: :ai_react_register_tool
  def register_tool_action, do: @register_tool

  @doc "Returns the action atom for unregistering a tool."
  @spec unregister_tool_action() :: :ai_react_unregister_tool
  def unregister_tool_action, do: @unregister_tool

  @doc "Returns the legacy action atom for handling tool results (no-op in delegated mode)."
  @spec tool_result_action() :: :ai_react_tool_result
  def tool_result_action, do: @tool_result

  @doc "Returns the legacy action atom for handling streaming deltas (no-op in delegated mode)."
  @spec llm_partial_action() :: :ai_react_llm_partial
  def llm_partial_action, do: @llm_partial

  @doc "Returns the action atom for request cancellation."
  @spec cancel_action() :: :ai_react_cancel
  def cancel_action, do: @cancel

  @doc "Returns the action atom for handling request rejections."
  @spec request_error_action() :: :ai_react_request_error
  def request_error_action, do: @request_error

  @doc "Returns the action atom for updating tool context."
  @spec set_tool_context_action() :: :ai_react_set_tool_context
  def set_tool_context_action, do: @set_tool_context

  @doc "Returns the action atom for updating the base system prompt."
  @spec set_system_prompt_action() :: :ai_react_set_system_prompt
  def set_system_prompt_action, do: @set_system_prompt

  @doc "Returns the legacy action atom for direct runtime stream events (no-op in delegated mode)."
  @spec runtime_event_action() :: :ai_react_runtime_event
  def runtime_event_action, do: @runtime_event

  @action_specs %{
    @start => %{
      schema:
        Zoi.object(%{
          query: Zoi.string(),
          request_id: Zoi.string() |> Zoi.optional(),
          model: Zoi.any() |> Zoi.optional(),
          model_name: Zoi.string() |> Zoi.optional(),
          max_iterations: Zoi.integer() |> Zoi.optional(),
          system_prompt: Zoi.string() |> Zoi.optional(),
          tools: Zoi.any() |> Zoi.optional(),
          tool_context: Zoi.map() |> Zoi.optional(),
          req_http_options: Zoi.list(Zoi.any()) |> Zoi.optional(),
          llm_opts: Zoi.any() |> Zoi.optional(),
          initial_messages: Zoi.list(Zoi.any()) |> Zoi.optional()
        }),
      doc: "Start a delegated ReAct conversation with a user query",
      name: "ai.react.start"
    },
    @cancel => %{
      schema:
        Zoi.object(%{
          request_id: Zoi.string() |> Zoi.optional(),
          reason: Zoi.atom() |> Zoi.default(:user_cancelled)
        }),
      doc: "Cancel an in-flight ReAct request",
      name: "ai.react.cancel"
    },
    @steer => %{
      schema:
        Zoi.object(%{
          texts: Zoi.list(Zoi.string()) |> Zoi.default([]),
          newest_id: Zoi.string() |> Zoi.optional(),
          conversation_id: Zoi.string() |> Zoi.optional()
        }),
      doc: "Inject mid-turn steer messages into the active run",
      name: "ai.react.steer"
    },
    @request_error => %{
      schema:
        Zoi.object(%{
          request_id: Zoi.string(),
          reason: Zoi.atom(),
          message: Zoi.string()
        }),
      doc: "Handle request rejection event",
      name: "ai.react.request_error"
    },
    @register_tool => %{
      schema: Zoi.object(%{tool_module: Zoi.atom()}),
      doc: "Register a new tool dynamically at runtime",
      name: "ai.react.register_tool"
    },
    @unregister_tool => %{
      schema: Zoi.object(%{tool_name: Zoi.string()}),
      doc: "Unregister a tool by name",
      name: "ai.react.unregister_tool"
    },
    @set_tool_context => %{
      schema: Zoi.object(%{tool_context: Zoi.map()}),
      doc: "Update the persistent base tool context",
      name: "ai.react.set_tool_context"
    },
    @set_system_prompt => %{
      schema: Zoi.object(%{system_prompt: Zoi.string()}),
      doc: "Update the persistent base system prompt",
      name: "ai.react.set_system_prompt"
    },
    @worker_event => %{
      schema: Zoi.object(%{request_id: Zoi.string(), event: Zoi.map()}),
      doc: "Handle delegated ReAct runtime event envelopes",
      name: "ai.react.worker.event"
    },
    @worker_child_started => %{
      schema:
        Zoi.object(%{
          parent_id: Zoi.string() |> Zoi.optional(),
          child_id: Zoi.string() |> Zoi.optional(),
          child_module: Zoi.any() |> Zoi.optional(),
          tag: Zoi.any(),
          pid: Zoi.any(),
          meta: Zoi.map() |> Zoi.default(%{})
        }),
      doc: "Handle worker child started lifecycle signal",
      name: "jido.agent.child.started"
    },
    @worker_child_exit => %{
      schema:
        Zoi.object(%{
          tag: Zoi.any(),
          pid: Zoi.any(),
          reason: Zoi.any()
        }),
      doc: "Handle worker child exit lifecycle signal",
      name: "jido.agent.child.exit"
    },
    # Legacy compatibility actions kept as no-op adapters.
    @llm_result => %{
      schema: Zoi.object(%{call_id: Zoi.string(), result: Zoi.any()}),
      doc: "Legacy no-op in delegated ReAct mode",
      name: "ai.react.llm_result"
    },
    @tool_result => %{
      schema: Zoi.object(%{call_id: Zoi.string(), tool_name: Zoi.string(), result: Zoi.any()}),
      doc: "Legacy no-op in delegated ReAct mode",
      name: "ai.react.tool_result"
    },
    @llm_partial => %{
      schema:
        Zoi.object(%{
          call_id: Zoi.string(),
          delta: Zoi.string(),
          chunk_type: Zoi.atom() |> Zoi.default(:content)
        }),
      doc: "Legacy no-op in delegated ReAct mode",
      name: "ai.react.llm_partial"
    },
    @runtime_event => %{
      schema: Zoi.object(%{request_id: Zoi.string(), event: Zoi.map()}),
      doc: "Legacy no-op in delegated ReAct mode",
      name: "ai.react.runtime_event"
    }
  }

  @impl true
  def action_spec(action), do: Map.get(@action_specs, action)

  @impl true
  def signal_routes(_ctx) do
    [
      {"ai.react.query", {:strategy_cmd, @start}},
      {"ai.react.cancel", {:strategy_cmd, @cancel}},
      {"ai.react.steer", {:strategy_cmd, @steer}},
      {"ai.request.error", {:strategy_cmd, @request_error}},
      {"ai.react.register_tool", {:strategy_cmd, @register_tool}},
      {"ai.react.unregister_tool", {:strategy_cmd, @unregister_tool}},
      {"ai.react.set_tool_context", {:strategy_cmd, @set_tool_context}},
      {"ai.react.set_system_prompt", {:strategy_cmd, @set_system_prompt}},
      {"ai.react.worker.event", {:strategy_cmd, @worker_event}},
      {"jido.agent.child.started", {:strategy_cmd, @worker_child_started}},
      {"jido.agent.child.exit", {:strategy_cmd, @worker_child_exit}},
      {"ai.llm.delta", Jido.Actions.Control.Noop},
      {"ai.llm.response", Jido.Actions.Control.Noop},
      {"ai.llm.turn.started", Jido.Actions.Control.Noop},
      {"ai.llm.turn.completed", Jido.Actions.Control.Noop},
      {"ai.tool.started", Jido.Actions.Control.Noop},
      {"ai.tool.result", Jido.Actions.Control.Noop},
      {"ai.request.started", Jido.Actions.Control.Noop},
      {"ai.request.completed", Jido.Actions.Control.Noop},
      {"ai.request.failed", Jido.Actions.Control.Noop},
      {"ai.usage", Jido.Actions.Control.Noop},
      {"ai.context", Jido.Actions.Control.Noop}
    ]
  end

  @impl true
  def snapshot(%Agent{} = agent, _ctx) do
    state = StratState.get(agent, %{})
    status = snapshot_status(state[:status])
    config = state[:config] || %{}

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:success, :failure],
      result: state[:result],
      details: build_snapshot_details(state, config)
    }
  end

  defp snapshot_status(:completed), do: :success
  defp snapshot_status(:error), do: :failure
  defp snapshot_status(:idle), do: :idle
  defp snapshot_status(_), do: :running

  defp build_snapshot_details(state, config) do
    conversation = state |> snapshot_thread(config) |> Thread.to_messages()

    trace_summary =
      state
      |> Map.get(:request_traces, %{})
      |> Enum.map(fn {request_id, trace} ->
        {request_id,
         %{
           events: request_trace_event_count(trace),
           truncated?: trace.truncated?
         }}
      end)
      |> Map.new()

    %{
      phase: state[:status],
      iteration: state[:iteration],
      termination_reason: state[:termination_reason],
      streaming_text: state[:streaming_text],
      streaming_thinking: state[:streaming_thinking],
      thinking_trace: thinking_trace(state),
      usage: state[:usage],
      duration_ms: calculate_duration(state[:started_at]),
      tool_calls: format_tool_calls(state[:pending_tool_calls] || []),
      current_llm_call_id: state[:current_llm_call_id],
      active_request_id: state[:active_request_id],
      checkpoint_token: state[:checkpoint_token],
      cancel_reason: state[:cancel_reason],
      worker_pid: state[:react_worker_pid],
      worker_status: state[:react_worker_status],
      trace_summary: trace_summary,
      model: config[:model],
      max_iterations: config[:max_iterations],
      streaming: config[:streaming],
      request_policy: config[:request_policy],
      runtime_adapter: true,
      tool_timeout_ms: config[:tool_timeout_ms],
      tool_max_retries: config[:tool_max_retries],
      tool_retry_backoff_ms: config[:tool_retry_backoff_ms],
      available_tools: Enum.map(Map.get(config, :tools, []), & &1.name()),
      conversation: conversation
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == %{} or v == [] end)
    |> Map.new()
  end

  defp calculate_duration(nil), do: nil
  defp calculate_duration(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp format_tool_calls([]), do: []

  defp format_tool_calls(pending_tool_calls) do
    Enum.map(pending_tool_calls, fn tc ->
      %{
        id: tc.id,
        name: tc.name,
        arguments: tc.arguments,
        status: if(tc.result == nil, do: :running, else: :completed),
        result: tc.result
      }
    end)
  end

  @impl true
  def init(%Agent{} = agent, ctx) do
    config = build_config(agent, ctx)

    state =
      %{
        status: :idle,
        iteration: 0,
        thread: Thread.new(system_prompt: config[:system_prompt]),
        run_thread: nil,
        pending_tool_calls: [],
        final_answer: nil,
        result: nil,
        current_llm_call_id: nil,
        termination_reason: nil,
        run_tool_context: %{},
        run_req_http_options: [],
        run_llm_opts: [],
        run_tools: nil,
        run_model: nil,
        run_model_name: nil,
        last_run_model: nil,
        last_run_model_name: nil,
        run_max_iterations: nil,
        run_system_prompt: nil,
        raw_streaming_text: "",
        active_request_id: nil,
        cancel_reason: nil,
        usage: %{},
        started_at: nil,
        streaming_text: "",
        streaming_thinking: "",
        thinking_trace: [],
        checkpoint_token: nil,
        request_traces: %{},
        react_worker_pid: nil,
        react_worker_status: :missing,
        pending_worker_start: nil,
        agent_id: Map.get(agent, :id)
      }
      |> Helpers.apply_to_state([Helpers.update_config(config)])

    agent = put_strategy_state(agent, state)

    # Check for mid-turn recovery after init (clears __recovery__ from state)
    agent = Magus.Agents.Recovery.maybe_recover(agent)

    {agent, []}
  end

  @impl true
  def cmd(%Agent{} = agent, instructions, ctx) do
    {agent, directives_rev} =
      Enum.reduce(instructions, {agent, []}, fn instruction, {acc_agent, acc_directives} ->
        case process_instruction(acc_agent, instruction, ctx) do
          {new_agent, new_directives} ->
            {new_agent, Enum.reverse(new_directives, acc_directives)}

          :noop ->
            {acc_agent, acc_directives}
        end
      end)

    agent = strip_thinking_from_thread(agent)
    {agent, Enum.reverse(directives_rev)}
  end

  defp process_instruction(
         agent,
         %Jido.Instruction{action: action, params: params} = instruction,
         ctx
       ) do
    case normalize_action(action) do
      @start ->
        state = StratState.get(agent, %{})
        config = state[:config] || %{}
        run_model = params |> Map.get(:model) |> normalize_run_model()
        run_model_name = params |> Map.get(:model_name) |> normalize_run_model_name()
        effective_model = run_model || config[:model]
        provider_opt_keys_by_string = provider_opt_keys_by_string(effective_model)
        run_max_iterations = params |> Map.get(:max_iterations) |> normalize_run_max_iterations()
        run_system_prompt = params |> Map.get(:system_prompt) |> normalize_run_system_prompt()
        run_tools = params |> Map.get(:tools) |> normalize_run_tools()
        run_context = Map.get(params, :tool_context) || %{}

        run_req_http_options =
          params |> Map.get(:req_http_options, []) |> normalize_req_http_options()

        run_llm_opts =
          params |> Map.get(:llm_opts, []) |> normalize_llm_opts(provider_opt_keys_by_string)

        agent
        |> set_run_tool_context(run_context)
        |> set_run_req_http_options(run_req_http_options)
        |> set_run_llm_opts(run_llm_opts)
        |> set_run_tools(run_tools)
        |> set_run_model(run_model)
        |> set_run_model_name(run_model_name)
        |> set_run_max_iterations(run_max_iterations)
        |> set_run_system_prompt(run_system_prompt)
        |> process_start(params)

      @cancel ->
        process_cancel(agent, params)

      @steer ->
        process_steer(agent, params)

      @request_error ->
        process_request_error(agent, params)

      @register_tool ->
        process_register_tool(agent, params)

      @unregister_tool ->
        process_unregister_tool(agent, params)

      @set_tool_context ->
        process_set_tool_context(agent, params)

      @set_system_prompt ->
        process_set_system_prompt(agent, params)

      @worker_event ->
        process_worker_event(agent, params)

      @worker_child_started ->
        process_worker_child_started(agent, params)

      @worker_child_exit ->
        process_worker_child_exit(agent, params)

      # Legacy compatibility no-ops in delegated mode.
      legacy when legacy in [@llm_result, @tool_result, @llm_partial, @runtime_event] ->
        {agent, []}

      _ ->
        Helpers.maybe_execute_action_instruction(agent, instruction, ctx)
    end
  end

  defp process_start(agent, %{query: query} = params) when is_binary(query) do
    state = StratState.get(agent, %{})
    config = state[:config] || %{}
    request_id = Map.get(params, :request_id, generate_call_id())
    run_id = request_id

    # Tag this process's logs so every plugin line emitted while handling the
    # turn (persistence, errors, etc.) is greppable by request_id/run_id.
    Logger.metadata(request_id: request_id, run_id: run_id)

    if busy?(state, config) do
      directive =
        Directive.EmitRequestError.new!(%{
          request_id: request_id,
          reason: :busy,
          message: "Agent is busy (status: #{state[:status]})"
        })

      {agent, [directive]}
    else
      run_tool_context = Map.get(state, :run_tool_context, %{})
      effective_tool_context = Map.merge(config[:base_tool_context] || %{}, run_tool_context)
      run_model = Map.get(state, :run_model)
      run_max_iterations = Map.get(state, :run_max_iterations)
      run_system_prompt = Map.get(state, :run_system_prompt)
      run_tools = Map.get(state, :run_tools)
      run_model_name = Map.get(state, :run_model_name)
      run_req_http_options = Map.get(state, :run_req_http_options, [])
      base_req_http_options = normalize_req_http_options(config[:base_req_http_options])
      effective_req_http_options = base_req_http_options ++ run_req_http_options
      run_llm_opts = Map.get(state, :run_llm_opts, [])
      provider_opt_keys_by_string = provider_opt_keys_by_string(run_model || config[:model])
      base_llm_opts = normalize_llm_opts(config[:base_llm_opts], provider_opt_keys_by_string)

      effective_llm_opts =
        base_llm_opts
        |> Keyword.merge(run_llm_opts)
        |> maybe_put_credential_actor_id(effective_tool_context[:acting_user_id])

      effective_tools = run_tools || config[:tools] || []
      effective_actions_by_name = Map.new(effective_tools, &{&1.name(), &1})

      runtime_config =
        runtime_config_from_strategy(config,
          model: run_model,
          max_iterations: run_max_iterations,
          system_prompt: run_system_prompt,
          tools: effective_actions_by_name,
          req_http_options: effective_req_http_options,
          llm_opts: effective_llm_opts
        )

      # TODO refactor/fix Threads upstream to support images
      #
      # initial_messages from Builder contain full context with images preserved.
      # When present, they bypass Thread (which strips image ContentParts).
      # Thread is only used for the agentic loop (tool results, assistant responses).
      initial_messages = Map.get(params, :initial_messages)

      {run_thread, thread_messages} =
        case initial_messages do
          msgs when is_list(msgs) and msgs != [] ->
            # Thread starts clean — agentic loop only. Query is in initial_messages.
            prompt = run_system_prompt || config[:system_prompt]
            thread = Thread.new(system_prompt: prompt)
            {thread, Thread.to_messages(thread)}

          _ ->
            # Fallback: no initial_messages (e.g. non-Magus callers, tests).
            # Build thread from in-memory state + append user query.
            base_thread =
              state
              |> strategy_thread(config)
              |> maybe_override_thread_system_prompt(run_system_prompt)

            thread = Thread.append_user(base_thread, query)
            {thread, Thread.to_messages(thread)}
        end

      worker_start_payload =
        %{
          request_id: request_id,
          run_id: run_id,
          query: query,
          config: runtime_config,
          thread_messages: thread_messages,
          task_supervisor: config[:runtime_task_supervisor],
          # This code runs inside the parent agent server process. The worker's
          # runtime task attaches itself to this pid for the duration of the run
          # so the idle-timeout lifecycle cannot hibernate the agent mid-turn.
          parent_pid: self(),
          context:
            Map.merge(effective_tool_context, %{
              request_id: request_id,
              run_id: run_id,
              agent_id: state[:agent_id] || Map.get(agent, :id),
              observability: config[:observability] || %{}
            })
        }
        # The worker schema validates initial_messages as an (optional) list;
        # an explicit nil fails validation and kills the worker, so only put
        # the key when there is a real list (absent on the fallback path).
        |> then(fn payload ->
          case initial_messages do
            msgs when is_list(msgs) -> Map.put(payload, :initial_messages, msgs)
            _ -> payload
          end
        end)

      {new_state, directives} = ensure_worker_start(state, worker_start_payload)

      new_state =
        new_state
        |> Map.put(:status, :awaiting_llm)
        |> Map.put(:active_request_id, request_id)
        |> Map.put(:current_llm_call_id, nil)
        |> Map.put(:iteration, 1)
        |> Map.put(:result, nil)
        |> Map.put(:termination_reason, nil)
        |> Map.put(:started_at, System.monotonic_time(:millisecond))
        |> Map.put(:streaming_text, "")
        |> Map.put(:raw_streaming_text, "")
        |> Map.put(:streaming_thinking, "")
        |> Map.put(:pending_tool_calls, [])
        |> Map.put(:cancel_reason, nil)
        |> Map.put(:checkpoint_token, nil)
        |> Map.put(:last_run_model, run_model || config[:model])
        |> Map.put(:last_run_model_name, run_model_name || run_model || config[:model])
        |> Map.put(:run_thread, run_thread)
        |> ensure_request_trace(request_id)

      context_signal =
        maybe_context_signal(
          run_system_prompt || config[:system_prompt],
          effective_tools,
          initial_messages || thread_messages,
          run_model || config[:model]
        )

      directives =
        case context_signal do
          nil -> directives
          signal -> [AgentDirective.emit(signal) | directives]
        end

      {put_strategy_state(agent, new_state), directives}
    end
  end

  defp process_start(agent, _params), do: {agent, []}

  defp process_cancel(agent, params) do
    state = StratState.get(agent, %{})
    request_id = Map.get(params, :request_id, state[:active_request_id])
    reason = Map.get(params, :reason, :user_cancelled)

    should_cancel? =
      is_binary(request_id) and request_id == state[:active_request_id] and
        is_pid(state[:react_worker_pid]) and
        Process.alive?(state[:react_worker_pid])

    directives =
      if should_cancel? do
        [
          AgentDirective.emit_to_pid(
            worker_cancel_signal(request_id, reason),
            state[:react_worker_pid]
          )
        ]
      else
        []
      end

    new_state =
      if should_cancel? do
        Map.put(state, :cancel_reason, reason)
      else
        state
      end

    {put_strategy_state(agent, new_state), directives}
  end

  defp process_steer(agent, params) do
    state = StratState.get(agent, %{})

    case decide_steer(state, params) do
      {:inject, request_id, texts} ->
        {agent,
         [
           AgentDirective.emit_to_pid(
             worker_steer_signal(request_id, texts),
             state[:react_worker_pid]
           )
         ]}

      {:redispatch, conversation_id, newest_id} ->
        Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
          Magus.Agents.Steering.redispatch(conversation_id, newest_id)
        end)

        {agent, []}

      :noop ->
        {agent, []}
    end
  end

  @doc false
  def decide_steer(state, params) do
    request_id = state[:active_request_id]
    texts = Map.get(params, :texts) || Map.get(params, "texts") || []

    active? =
      is_binary(request_id) and is_pid(state[:react_worker_pid]) and
        Process.alive?(state[:react_worker_pid]) and
        state[:status] in [:awaiting_llm, :awaiting_tool]

    cond do
      active? ->
        {:inject, request_id, texts}

      true ->
        conversation_id = Map.get(params, :conversation_id) || Map.get(params, "conversation_id")
        newest_id = Map.get(params, :newest_id) || Map.get(params, "newest_id")

        if is_binary(conversation_id) and is_binary(newest_id) do
          {:redispatch, conversation_id, newest_id}
        else
          :noop
        end
    end
  end

  defp process_request_error(agent, %{request_id: request_id, reason: reason, message: message}) do
    state = StratState.get(agent, %{})

    new_state =
      Map.put(state, :last_request_error, %{
        request_id: request_id,
        reason: reason,
        message: message
      })

    {put_strategy_state(agent, new_state), []}
  end

  defp process_request_error(agent, _params), do: {agent, []}

  defp process_register_tool(agent, %{tool_module: module}) when is_atom(module) do
    state = StratState.get(agent, %{})
    config = state[:config]

    new_tools = [module | config[:tools]] |> Enum.uniq()
    new_actions_by_name = Map.put(config[:actions_by_name], module.name(), module)
    new_reqllm_tools = ToolAdapter.from_actions(new_tools)

    new_state =
      Helpers.apply_to_state(
        state,
        Helpers.update_tools_config(new_tools, new_actions_by_name, new_reqllm_tools)
      )

    {put_strategy_state(agent, new_state), []}
  end

  defp process_register_tool(agent, _params), do: {agent, []}

  defp process_unregister_tool(agent, %{tool_name: tool_name}) when is_binary(tool_name) do
    state = StratState.get(agent, %{})
    config = state[:config]

    new_tools = Enum.reject(config[:tools], fn m -> m.name() == tool_name end)
    new_actions_by_name = Map.delete(config[:actions_by_name], tool_name)
    new_reqllm_tools = ToolAdapter.from_actions(new_tools)

    new_state =
      Helpers.apply_to_state(
        state,
        Helpers.update_tools_config(new_tools, new_actions_by_name, new_reqllm_tools)
      )

    {put_strategy_state(agent, new_state), []}
  end

  defp process_unregister_tool(agent, _params), do: {agent, []}

  defp process_set_tool_context(agent, %{tool_context: new_context}) when is_map(new_context) do
    state = StratState.get(agent, %{})

    new_state =
      Helpers.apply_to_state(state, [
        Helpers.set_config_field(:base_tool_context, new_context)
      ])

    {put_strategy_state(agent, new_state), []}
  end

  defp process_set_tool_context(agent, _params), do: {agent, []}

  defp process_set_system_prompt(agent, %{system_prompt: prompt}) when is_binary(prompt) do
    state = StratState.get(agent, %{})
    run_thread = Map.get(state, :run_thread)
    base_thread = strategy_thread(state, state[:config] || %{})

    new_state =
      Helpers.apply_to_state(state, [
        Helpers.set_config_field(:system_prompt, prompt)
      ])
      |> Map.put(:thread, %{base_thread | system_prompt: prompt})
      |> then(fn updated ->
        if match?(%Thread{}, run_thread) do
          Map.put(updated, :run_thread, %{run_thread | system_prompt: prompt})
        else
          updated
        end
      end)

    {put_strategy_state(agent, new_state), []}
  end

  defp process_set_system_prompt(agent, _params), do: {agent, []}

  defp process_worker_child_started(agent, %{tag: tag, pid: pid}) when is_pid(pid) do
    state = StratState.get(agent, %{})

    if react_worker_tag?(tag) do
      pending = state[:pending_worker_start]

      base_state =
        state
        |> Map.put(:react_worker_pid, pid)
        |> Map.put(:react_worker_status, :ready)

      if is_map(pending) do
        directive = AgentDirective.emit_to_pid(worker_start_signal(pending), pid)

        new_state =
          base_state
          |> Map.put(:pending_worker_start, nil)
          |> Map.put(:react_worker_status, :running)

        {put_strategy_state(agent, new_state), [directive]}
      else
        {put_strategy_state(agent, base_state), []}
      end
    else
      {agent, []}
    end
  end

  defp process_worker_child_started(agent, _params), do: {agent, []}

  defp process_worker_child_exit(agent, %{tag: tag, pid: pid, reason: reason}) do
    state = StratState.get(agent, %{})

    if react_worker_tag?(tag) do
      tracked? = worker_pid_matches?(state[:react_worker_pid], pid)

      if tracked? do
        request_id = state[:active_request_id]

        base_state =
          state
          |> Map.put(:react_worker_pid, nil)
          |> Map.put(:react_worker_status, :missing)
          |> Map.put(:pending_worker_start, nil)

        if is_binary(request_id) and state[:status] in [:awaiting_llm, :awaiting_tool] do
          error = {:react_worker_exit, reason}

          failure_signal =
            Signal.RequestFailed.new!(%{
              request_id: request_id,
              error: error,
              run_id: request_id
            })

          failed_state =
            base_state
            |> Map.put(:status, :error)
            |> Map.put(:termination_reason, :error)
            |> Map.put(:result, inspect(error))
            |> Map.put(:active_request_id, nil)
            |> Map.put(:run_thread, nil)
            |> clear_run_state()

          {put_strategy_state(agent, failed_state), [AgentDirective.emit(failure_signal)]}
        else
          {put_strategy_state(agent, base_state), []}
        end
      else
        {agent, []}
      end
    else
      {agent, []}
    end
  end

  defp process_worker_event(agent, %{event: event} = params) when is_map(event) do
    state = StratState.get(agent, %{})
    event = normalize_event_map(event)
    request_id = event_field(event, :request_id, params[:request_id] || state[:active_request_id])

    state = append_trace_event(state, request_id, event)
    {new_state, signals} = apply_runtime_event(state, event)
    directives = Enum.map(signals, &AgentDirective.emit/1)

    kind = event_kind(event)
    new_state = maybe_mark_worker_ready(new_state, kind)

    {put_strategy_state(agent, new_state), directives}
  end

  defp process_worker_event(agent, _params), do: {agent, []}

  defp apply_runtime_event(state, event) do
    kind = event_kind(event)
    iteration = event_field(event, :iteration, state[:iteration] || 0)
    request_id = event_field(event, :request_id, state[:active_request_id])
    llm_call_id = event_field(event, :llm_call_id, state[:current_llm_call_id])
    data = event_field(event, :data, %{})

    base_state =
      state
      |> Map.put(:active_request_id, request_id)
      |> Map.put(:iteration, iteration)
      |> Map.put(:current_llm_call_id, llm_call_id)

    case kind do
      :request_started ->
        query = event_field(data, :query, "")

        started_state =
          base_state
          |> Map.put(:status, :awaiting_llm)
          |> Map.put(:result, nil)
          |> Map.put(:termination_reason, nil)
          |> Map.put(:started_at, event_field(event, :at_ms, System.monotonic_time(:millisecond)))
          |> Map.put(:streaming_text, "")
          |> Map.put(:raw_streaming_text, "")
          |> Map.put(:streaming_thinking, "")
          |> ensure_request_trace(request_id)

        signal =
          Signal.RequestStarted.new!(%{request_id: request_id, query: query, run_id: request_id})

        {started_state, [signal]}

      :llm_started ->
        turn_id = runtime_turn_id(request_id, iteration)

        updated =
          base_state
          |> Map.put(:status, :awaiting_llm)
          |> Map.put(:streaming_text, "")
          |> Map.put(:raw_streaming_text, "")
          |> Map.put(:streaming_thinking, "")

        signal =
          CoreSignal.new!(
            "ai.llm.turn.started",
            %{
              request_id: request_id,
              call_id: llm_call_id || "",
              turn_id: turn_id,
              iteration: iteration,
              model: config_model(state)
            },
            source: @source
          )

        {updated, [signal]}

      :llm_delta ->
        chunk_type = event_field(data, :chunk_type, :content)
        delta = event_field(data, :delta, "")
        turn_id = runtime_turn_id(request_id, iteration)

        {updated, emitted_delta} =
          case chunk_type do
            :thinking ->
              {
                Map.update(base_state, :streaming_thinking, delta, &(&1 <> delta)),
                delta
              }

            :tool_call ->
              {base_state, ""}

            _ ->
              apply_content_delta(base_state, delta)
          end

        accumulated =
          case chunk_type do
            :thinking -> Map.get(updated, :streaming_thinking, "")
            _ -> Map.get(updated, :streaming_text, "")
          end

        signal =
          CoreSignal.new!(
            "ai.llm.delta",
            %{
              call_id: llm_call_id || "",
              request_id: request_id,
              turn_id: turn_id,
              iteration: iteration,
              delta: emitted_delta,
              chunk_type: chunk_type,
              text: accumulated
            },
            source: @source
          )

        {updated, [signal]}

      :llm_completed ->
        turn_type = event_field(data, :turn_type, :final_answer)
        raw_text = event_field(data, :text, "")
        text = normalize_turn_text(turn_type, raw_text)
        thinking_content = event_field(data, :thinking_content)
        tool_calls = event_field(data, :tool_calls, [])
        usage = event_field(data, :usage, %{})
        call_id = llm_call_id || event_field(data, :call_id, "")
        turn_id = runtime_turn_id(request_id, iteration)

        pending_tool_calls =
          Enum.map(tool_calls, fn tc ->
            %{
              id: event_field(tc, :id, ""),
              name: event_field(tc, :name, ""),
              arguments: event_field(tc, :arguments, %{}),
              result: nil
            }
          end)

        updated =
          base_state
          |> Map.put(:status, if(turn_type == :tool_calls, do: :awaiting_tool, else: :completed))
          |> Map.put(:pending_tool_calls, pending_tool_calls)
          |> append_assistant_to_run_thread(turn_type, text, tool_calls, thinking_content)
          |> Map.update(:usage, usage || %{}, fn existing ->
            merge_usage(existing, usage || %{})
          end)
          |> maybe_finalize_streaming_text(turn_type, text)
          |> maybe_append_thinking_trace(thinking_content)
          |> maybe_put_result(turn_type, text)

        llm_signal =
          CoreSignal.new!(
            "ai.llm.response",
            %{
              call_id: call_id,
              request_id: request_id,
              turn_id: turn_id,
              iteration: iteration,
              result:
                {:ok,
                 %{
                   type: turn_type,
                   text: text,
                   projected_text: Map.get(updated, :streaming_text, ""),
                   thinking_content: thinking_content,
                   tool_calls: tool_calls,
                   usage: usage,
                   citations: event_field(data, :citations, [])
                 }}
            },
            source: @source
          )

        turn_completed_signal =
          CoreSignal.new!(
            "ai.llm.turn.completed",
            %{
              request_id: request_id,
              call_id: call_id,
              turn_id: turn_id,
              iteration: iteration,
              turn_type: turn_type,
              text: text,
              projected_text: Map.get(updated, :streaming_text, ""),
              tool_calls: tool_calls,
              usage: usage
            },
            source: @source
          )

        usage_signal =
          maybe_usage_signal(
            call_id,
            config_model(state),
            usage,
            event_field(data, :generation_id)
          )

        {updated, Enum.reject([llm_signal, turn_completed_signal, usage_signal], &is_nil/1)}

      :tool_started ->
        tool_call_id = event_field(data, :tool_call_id, event_field(event, :tool_call_id, ""))
        tool_name = event_field(data, :tool_name, event_field(event, :tool_name, ""))
        arguments = event_field(data, :arguments, %{})
        turn_id = runtime_turn_id(request_id, iteration)

        signal =
          CoreSignal.new!("ai.tool.started", %{
            request_id: request_id,
            turn_id: turn_id,
            iteration: iteration,
            call_id: tool_call_id,
            tool_name: tool_name,
            arguments: arguments
          })

        {Map.put(base_state, :status, :awaiting_tool), [signal]}

      :tool_completed ->
        tool_call_id = event_field(data, :tool_call_id, event_field(event, :tool_call_id, ""))
        tool_name = event_field(data, :tool_name, event_field(event, :tool_name, ""))
        tool_result = event_field(data, :result, {:error, :unknown})
        turn_id = runtime_turn_id(request_id, iteration)

        updated =
          base_state
          |> Map.update(:pending_tool_calls, [], fn pending ->
            Enum.map(pending, fn tc ->
              if tc.id == tool_call_id, do: %{tc | result: tool_result}, else: tc
            end)
          end)
          |> append_tool_result_to_run_thread(tool_call_id, tool_name, tool_result)

        signal =
          CoreSignal.new!(
            "ai.tool.result",
            %{
              request_id: request_id,
              turn_id: turn_id,
              iteration: iteration,
              call_id: tool_call_id,
              tool_name: tool_name,
              result: tool_result
            },
            source: @source
          )

        {updated, [signal]}

      :request_completed ->
        result = event_field(data, :result)
        termination_reason = event_field(data, :termination_reason, :final_answer)
        usage = event_field(data, :usage, %{})

        updated =
          base_state
          |> Map.put(:status, :completed)
          |> Map.put(:result, result)
          |> Map.put(:termination_reason, termination_reason)
          |> Map.put(:usage, usage || %{})
          |> Map.put(:thread, nil)
          |> Map.put(:run_thread, nil)
          |> Map.put(:active_request_id, nil)
          |> clear_run_state()

        signal =
          Signal.RequestCompleted.new!(%{
            request_id: request_id,
            result: result,
            run_id: request_id
          })

        {updated, [signal]}

      :request_failed ->
        error = event_field(data, :error, :unknown_error)

        updated =
          base_state
          |> Map.put(:status, :error)
          |> Map.put(:result, inspect(error))
          |> Map.put(:termination_reason, :error)
          |> Map.put(:thread, nil)
          |> Map.put(:run_thread, nil)
          |> Map.put(:active_request_id, nil)
          |> clear_run_state()

        signal =
          Signal.RequestFailed.new!(%{request_id: request_id, error: error, run_id: request_id})

        {updated, [signal]}

      :request_cancelled ->
        reason = event_field(data, :reason, :cancelled)
        error = {:cancelled, reason}

        updated =
          base_state
          |> Map.put(:status, :error)
          |> Map.put(:result, inspect(error))
          |> Map.put(:termination_reason, :cancelled)
          |> Map.put(:cancel_reason, reason)
          |> Map.put(:thread, nil)
          |> Map.put(:run_thread, nil)
          |> Map.put(:active_request_id, nil)
          |> clear_run_state()

        signal =
          Signal.RequestFailed.new!(%{request_id: request_id, error: error, run_id: request_id})

        {updated, [signal]}

      :checkpoint ->
        token = event_field(data, :token)

        updated =
          base_state
          |> Map.put(:checkpoint_token, token)
          |> then(fn state_after_checkpoint ->
            if state[:status] in [:completed, :error] and is_nil(state[:active_request_id]) do
              Map.put(state_after_checkpoint, :active_request_id, nil)
            else
              state_after_checkpoint
            end
          end)

        {updated, []}

      _ ->
        {base_state, []}
    end
  end

  defp maybe_append_thinking_trace(state, nil), do: state
  defp maybe_append_thinking_trace(state, ""), do: state

  defp maybe_append_thinking_trace(state, thinking_content) do
    trace_entry = %{
      call_id: state[:current_llm_call_id],
      iteration: state[:iteration],
      thinking: thinking_content
    }

    Map.update(state, :thinking_trace, [trace_entry], fn trace -> [trace_entry | trace] end)
  end

  defp maybe_put_result(state, :final_answer, result), do: Map.put(state, :result, result)
  defp maybe_put_result(state, _turn_type, _result), do: state

  # Always emit a usage signal for a completed LLM turn, even when the provider
  # omitted token counts. A completed turn consumed tokens and (for non-empty
  # turns) persists an agent message, so a MessageUsage row MUST exist and link
  # to that message for billing integrity. Dropping the signal on empty usage
  # left ~25% of agent responses with no usage record (OpenRouter intermittently
  # omits usage depending on upstream routing). When counts are unavailable we
  # record zeros — a row with total_tokens == 0 is the auditable marker that the
  # turn's usage could not be captured, far better than a silent gap.
  defp maybe_usage_signal(call_id, model, usage, generation_id) do
    usage = usage || %{}
    input_tokens = Map.get(usage, :input_tokens, 0)
    output_tokens = Map.get(usage, :output_tokens, 0)

    Signal.Usage.new!(%{
      call_id: call_id,
      model: model || "",
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      metadata: usage_signal_metadata(generation_id, usage)
    })
  end

  # The Usage signal schema only allows input/output/total/metadata (metadata is
  # a free-form map), so the provider's cached-read count is forwarded via
  # metadata. `ContextPlugin` reads `metadata.cached_tokens` to populate the
  # donut's `last_cached_tokens`. cached_tokens defaults to 0 when absent.
  defp usage_signal_metadata(generation_id, usage) do
    base = %{cached_tokens: resolve_cached_tokens(usage)}

    if is_binary(generation_id) and generation_id != "" do
      Map.put(base, :generation_id, generation_id)
    else
      base
    end
  end

  # Resolve provider cached-read tokens from the usage map. Mirrors the canonical
  # fallback chain in Magus.Chat.MessageUsage.Changes.ExtractTokens
  # (lib/magus/chat/message_usage/changes/extract_tokens.ex) — keep them in sync.
  defp resolve_cached_tokens(usage) do
    usage = usage || %{}
    details = usage["prompt_tokens_details"] || usage[:prompt_tokens_details] || %{}

    usage[:cached_input] || usage[:cached_tokens] ||
      details["cached_tokens"] || details[:cached_tokens] || 0
  end

  # Emit a one-shot `ai.context` signal at the start of a turn carrying the
  # assembled-context breakdown (resting context: system prompt + tools +
  # message history for this turn). The `ContextPlugin` upserts the snapshot and
  # broadcasts `context.updated`. Best-effort: any failure to assemble the
  # report (e.g. tool schema serialization) is swallowed so the turn proceeds.
  defp maybe_context_signal(system_prompt, tools, messages, model_key) do
    max_context = resolve_max_context(model_key)

    breakdown =
      ContextReport.build(%{
        system_prompt: system_prompt,
        tools: tools || [],
        messages: messages || [],
        model_key: model_key,
        max_context: max_context
      })

    CoreSignal.new!(
      "ai.context",
      %{breakdown: breakdown, model_key: model_key, max_context: max_context},
      source: @source
    )
  rescue
    e ->
      Logger.warning("ReactStrategy ai.context assembly failed: #{Exception.message(e)}")
      nil
  end

  # Resolve the resolved model's context window. For an auto-routed conversation
  # the `model_key` is already the concrete model the turn uses. Falls back to
  # 128_000 when the model is unknown or has no recorded `context_window`.
  defp resolve_max_context(model_key) when is_binary(model_key) and model_key != "" do
    require Ash.Query

    Magus.Chat.Model
    |> Ash.Query.filter(key == ^model_key)
    |> Ash.Query.select([:context_window])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{context_window: cw}} when is_integer(cw) and cw > 0 -> cw
      _ -> 128_000
    end
  rescue
    _ -> 128_000
  end

  defp resolve_max_context(_model_key), do: 128_000

  defp merge_usage(existing, incoming) do
    Map.merge(existing || %{}, incoming || %{}, fn _k, left, right ->
      (left || 0) + (right || 0)
    end)
  end

  defp event_kind(event) do
    case event_field(event, :kind) do
      kind when is_atom(kind) -> kind
      kind when is_binary(kind) -> runtime_kind_from_string(kind)
      _ -> :unknown
    end
  end

  defp runtime_kind_from_string("request_started"), do: :request_started
  defp runtime_kind_from_string("llm_started"), do: :llm_started
  defp runtime_kind_from_string("llm_delta"), do: :llm_delta
  defp runtime_kind_from_string("llm_completed"), do: :llm_completed
  defp runtime_kind_from_string("tool_started"), do: :tool_started
  defp runtime_kind_from_string("tool_completed"), do: :tool_completed
  defp runtime_kind_from_string("checkpoint"), do: :checkpoint
  defp runtime_kind_from_string("request_completed"), do: :request_completed
  defp runtime_kind_from_string("request_failed"), do: :request_failed
  defp runtime_kind_from_string("request_cancelled"), do: :request_cancelled
  defp runtime_kind_from_string(_), do: :unknown

  defp runtime_turn_id(request_id, iteration)
       when is_binary(request_id) and request_id != "" and is_integer(iteration) and iteration > 0,
       do: "#{request_id}:#{iteration}"

  defp runtime_turn_id(request_id, _iteration) when is_binary(request_id) and request_id != "",
    do: request_id

  defp runtime_turn_id(_request_id, iteration) when is_integer(iteration) and iteration > 0,
    do: "turn:#{iteration}"

  defp runtime_turn_id(_request_id, _iteration), do: "turn:unknown"

  defp event_field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize_event_map(event) when is_map(event), do: event

  defp config_model(state) do
    Map.get(state, :run_model) ||
      state
      |> Map.get(:config, %{})
      |> Map.get(:model)
  end

  defp runtime_config_from_strategy(config, opts) do
    effective_model = opts |> Keyword.get(:model) |> normalize_run_model() || config[:model]
    provider_opt_keys_by_string = provider_opt_keys_by_string(effective_model)

    req_http_options =
      opts
      |> Keyword.get(:req_http_options, config[:base_req_http_options] || [])
      |> normalize_req_http_options()

    llm_opts =
      opts
      |> Keyword.get(:llm_opts, config[:base_llm_opts] || [])
      |> normalize_llm_opts(provider_opt_keys_by_string)

    runtime_opts = %{
      model: effective_model,
      system_prompt: Keyword.get(opts, :system_prompt, config[:system_prompt]),
      tools: Keyword.get(opts, :tools, config[:actions_by_name] || %{}),
      max_iterations:
        Keyword.get(opts, :max_iterations, config[:max_iterations])
        |> normalize_runtime_max_iterations(config),
      streaming: config[:streaming],
      req_http_options: req_http_options,
      llm_opts: llm_opts,
      # Per-request receive_timeout: the max gap between stream chunks before
      # the request is treated as hung. 10 minutes tolerates reasoning models
      # that think silently before the first chunk; true hangs are still
      # detected within this window and retried by the runner.
      llm_timeout_ms: config[:llm_timeout_ms] || 600_000,
      tool_timeout_ms: config[:tool_timeout_ms],
      tool_max_retries: config[:tool_max_retries],
      tool_retry_backoff_ms: config[:tool_retry_backoff_ms],
      emit_telemetry?: get_in(config, [:observability, :emit_telemetry?]),
      redact_tool_args?: get_in(config, [:observability, :redact_tool_args?]),
      capture_deltas?: get_in(config, [:observability, :emit_llm_deltas?]),
      runtime_task_supervisor: config[:runtime_task_supervisor]
    }

    ReActRuntimeConfig.new(runtime_opts)
  end

  defp set_run_tool_context(agent, context) when is_map(context) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_tool_context, context))
  end

  defp set_run_req_http_options(agent, req_http_options) when is_list(req_http_options) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_req_http_options, req_http_options))
  end

  # Carry the acting user's id as `:credential_actor_id` in the per-turn
  # llm_opts so `Magus.Agents.Clients.LLM.provider_options/2` can release an
  # owned provider's credentials to their owner at request time. The opt is
  # popped there before reaching ReqLLM. Absent an acting user, the opt is
  # simply omitted (fail-closed: the safe global-only fallback applies).
  defp maybe_put_credential_actor_id(llm_opts, actor_id) when is_binary(actor_id) do
    Keyword.put(llm_opts, :credential_actor_id, actor_id)
  end

  defp maybe_put_credential_actor_id(llm_opts, _actor_id), do: llm_opts

  defp set_run_llm_opts(agent, llm_opts) when is_list(llm_opts) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_llm_opts, llm_opts))
  end

  defp set_run_tools(agent, run_tools) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_tools, run_tools))
  end

  defp set_run_model(agent, run_model) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_model, run_model))
  end

  defp set_run_model_name(agent, run_model_name) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_model_name, run_model_name))
  end

  defp set_run_max_iterations(agent, run_max_iterations) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_max_iterations, run_max_iterations))
  end

  defp set_run_system_prompt(agent, run_system_prompt) do
    state = StratState.get(agent, %{})
    put_strategy_state(agent, Map.put(state, :run_system_prompt, run_system_prompt))
  end

  defp normalize_action({inner, _meta}), do: normalize_action(inner)
  defp normalize_action(action), do: action

  defp ensure_worker_start(state, worker_start_payload) do
    if is_pid(state[:react_worker_pid]) and Process.alive?(state[:react_worker_pid]) do
      directive =
        AgentDirective.emit_to_pid(
          worker_start_signal(worker_start_payload),
          state[:react_worker_pid]
        )

      new_state =
        state
        |> Map.put(:pending_worker_start, nil)
        |> Map.put(:react_worker_status, :running)

      {new_state, [directive]}
    else
      spawn_directive =
        AgentDirective.spawn_agent(
          Magus.Agents.Strategies.ReactStrategy.Worker.Agent,
          @worker_tag
        )

      new_state =
        state
        |> Map.put(:react_worker_pid, nil)
        |> Map.put(:react_worker_status, :starting)
        |> Map.put(:pending_worker_start, worker_start_payload)

      {new_state, [spawn_directive]}
    end
  end

  defp worker_start_signal(payload) do
    Jido.Signal.new!("ai.react.worker.start", payload, source: @source)
  end

  defp worker_cancel_signal(request_id, reason) do
    Jido.Signal.new!("ai.react.worker.cancel", %{request_id: request_id, reason: reason},
      source: @source
    )
  end

  defp worker_steer_signal(request_id, texts) do
    Jido.Signal.new!("ai.react.worker.steer", %{request_id: request_id, texts: texts},
      source: @source
    )
  end

  defp react_worker_tag?(tag), do: tag == @worker_tag or tag == Atom.to_string(@worker_tag)

  defp worker_pid_matches?(expected, actual) when is_pid(expected) and is_pid(actual),
    do: expected == actual

  defp worker_pid_matches?(_expected, _actual), do: true

  defp busy?(state, config) do
    config[:request_policy] == :reject and state[:status] in [:awaiting_llm, :awaiting_tool] and
      is_binary(state[:active_request_id])
  end

  defp maybe_mark_worker_ready(state, kind)
       when kind in [:request_completed, :request_failed, :request_cancelled] do
    Map.put(state, :react_worker_status, :ready)
  end

  defp maybe_mark_worker_ready(state, _kind), do: state

  defp strategy_thread(state, config) do
    case Map.get(state, :thread) do
      %Thread{} = thread ->
        thread

      _ ->
        Thread.new(system_prompt: config[:system_prompt])
    end
  end

  defp maybe_override_thread_system_prompt(%Thread{} = thread, nil), do: thread

  defp maybe_override_thread_system_prompt(%Thread{} = thread, prompt),
    do: %{thread | system_prompt: prompt}

  defp snapshot_thread(state, config) do
    case Map.get(state, :run_thread) do
      %Thread{} = thread -> thread
      _ -> strategy_thread(state, config)
    end
  end

  defp append_assistant_to_run_thread(state, turn_type, text, tool_calls, thinking_content) do
    thread = Map.get(state, :run_thread) || Map.get(state, :thread)

    case thread do
      %Thread{} = thread ->
        assistant_tool_calls = if turn_type == :tool_calls, do: tool_calls, else: nil
        assistant_content = text

        thinking_opts =
          case thinking_content do
            thinking when is_binary(thinking) and thinking != "" -> [thinking: thinking]
            _ -> []
          end

        Map.put(
          state,
          :run_thread,
          Thread.append_assistant(thread, assistant_content, assistant_tool_calls, thinking_opts)
        )

      _ ->
        state
    end
  end

  defp append_tool_result_to_run_thread(state, tool_call_id, tool_name, tool_result) do
    thread = Map.get(state, :run_thread) || Map.get(state, :thread)

    case thread do
      %Thread{} = thread when is_binary(tool_call_id) and is_binary(tool_name) ->
        content = Turn.format_tool_result_content(tool_result)

        Map.put(
          state,
          :run_thread,
          Thread.append_tool_result(thread, tool_call_id, tool_name, content)
        )

      _ ->
        state
    end
  end

  # Thread is no longer persisted between requests — each request loads
  # history from DB via initial_messages. The run_thread is cleared on
  # completion/failure/cancellation.

  defp strip_thinking_from_thread(agent) do
    state = StratState.get(agent, %{})

    cleaned_state =
      state
      |> maybe_strip_thread_thinking(:thread)
      |> maybe_strip_thread_thinking(:run_thread)

    put_strategy_state(agent, cleaned_state)
  end

  defp maybe_strip_thread_thinking(state, key) do
    case Map.get(state, key) do
      %Thread{entries: entries} = thread ->
        cleaned_entries =
          Enum.map(entries, fn
            %Thread.Entry{thinking: thinking} = entry
            when is_binary(thinking) and thinking != "" ->
              %{entry | thinking: nil}

            entry ->
              entry
          end)

        Map.put(state, key, %{thread | entries: cleaned_entries})

      _ ->
        state
    end
  end

  defp ensure_request_trace(state, request_id) when is_binary(request_id) do
    traces = Map.get(state, :request_traces, %{})
    trace = Map.get(traces, request_id, %{events: [], event_count: 0, truncated?: false})
    Map.put(state, :request_traces, Map.put(traces, request_id, trace))
  end

  defp ensure_request_trace(state, _request_id), do: state

  defp append_trace_event(state, request_id, event) when is_binary(request_id) do
    traces = Map.get(state, :request_traces, %{})
    trace = Map.get(traces, request_id, %{events: [], event_count: 0, truncated?: false})
    event_count = request_trace_event_count(trace)

    updated_trace =
      cond do
        trace.truncated? ->
          trace

        event_count < @request_trace_cap ->
          %{
            trace
            | events: [event | trace.events],
              event_count: event_count + 1
          }

        true ->
          %{trace | truncated?: true}
      end

    Map.put(state, :request_traces, Map.put(traces, request_id, updated_trace))
  end

  defp append_trace_event(state, _request_id, _event), do: state

  defp thinking_trace(state) do
    state
    |> Map.get(:thinking_trace, [])
    |> Enum.reverse()
  end

  defp request_trace_event_count(trace) when is_map(trace) do
    cond do
      is_integer(trace[:event_count]) and trace[:event_count] >= 0 ->
        trace[:event_count]

      is_list(trace[:events]) ->
        length(trace[:events])

      true ->
        0
    end
  end

  defp clear_run_state(state) do
    state
    |> Map.delete(:run_tool_context)
    |> Map.delete(:run_req_http_options)
    |> Map.delete(:run_llm_opts)
    |> Map.delete(:run_tools)
    |> Map.delete(:run_model)
    |> Map.delete(:run_model_name)
    |> Map.delete(:run_max_iterations)
    |> Map.delete(:run_system_prompt)
    |> Map.delete(:raw_streaming_text)
  end

  defp apply_content_delta(state, delta) when is_binary(delta) do
    previous_raw = state[:raw_streaming_text] || ""
    previous_visible = state[:streaming_text] || ""
    current_raw = previous_raw <> delta
    current_visible = ToolCallText.strip_pseudo_tool_payload(current_raw)

    visible_delta =
      case String.replace_prefix(current_visible, previous_visible, "") do
        ^current_visible -> ""
        value -> value
      end

    updated =
      state
      |> Map.put(:raw_streaming_text, current_raw)
      |> Map.put(:streaming_text, current_visible)

    {updated, visible_delta}
  end

  defp apply_content_delta(state, _delta), do: {state, ""}

  defp maybe_finalize_streaming_text(state, :final_answer, text) do
    current = state[:streaming_text] || ""

    final_text =
      cond do
        is_binary(current) and current != "" ->
          sanitize_assistant_text(current)

        is_binary(text) and text != "" ->
          sanitize_assistant_text(text)

        true ->
          ""
      end

    Map.put(state, :streaming_text, final_text)
  end

  defp maybe_finalize_streaming_text(state, _turn_type, _text), do: state

  defp normalize_turn_text(:final_answer, text) when is_binary(text) do
    sanitize_assistant_text(text)
  end

  defp normalize_turn_text(_turn_type, text), do: text

  defp sanitize_assistant_text(text) when is_binary(text) do
    text
    |> ToolCallText.strip_pseudo_tool_payload()
    |> String.trim()
  end

  defp sanitize_assistant_text(_), do: ""

  defp build_config(agent, ctx) do
    opts = ctx[:strategy_opts] || []
    observability_overrides = opts |> Keyword.get(:observability, %{}) |> normalize_map_opt()
    tool_context_opt = opts |> Keyword.get(:tool_context, %{}) |> normalize_map_opt()

    tools_modules =
      case Keyword.fetch(opts, :tools) do
        {:ok, mods} when is_list(mods) ->
          mods

        :error ->
          raise ArgumentError,
                "Jido.AI.Reasoning.ReAct.Strategy requires :tools option (list of Jido.Action modules)"
      end

    actions_by_name = Map.new(tools_modules, &{&1.name(), &1})
    reqllm_tools = ToolAdapter.from_actions(tools_modules)

    raw_model = Keyword.get(opts, :model, Map.get(agent.state, :model, @default_model))
    resolved_model = resolve_model_spec(raw_model)
    provider_opt_keys_by_string = provider_opt_keys_by_string(resolved_model)

    request_policy = validate_request_policy!(Keyword.get(opts, :request_policy, :reject))

    %{
      tools: tools_modules,
      reqllm_tools: reqllm_tools,
      actions_by_name: actions_by_name,
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt),
      model: resolved_model,
      max_iterations: Keyword.get(opts, :max_iterations, Magus.Config.max_iterations()),
      streaming: Keyword.get(opts, :streaming, true),
      request_policy: request_policy,
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, 15_000),
      tool_max_retries: Keyword.get(opts, :tool_max_retries, 1),
      tool_retry_backoff_ms: Keyword.get(opts, :tool_retry_backoff_ms, 200),
      runtime_adapter: true,
      runtime_task_supervisor: Keyword.get(opts, :runtime_task_supervisor),
      observability:
        Map.merge(
          %{
            emit_telemetry?: true,
            emit_lifecycle_signals?: true,
            redact_tool_args?: true,
            emit_llm_deltas?: true
          },
          observability_overrides
        ),
      agent_id: agent.id,
      base_tool_context: Map.get(agent.state, :tool_context) || tool_context_opt,
      base_req_http_options:
        opts |> Keyword.get(:req_http_options, []) |> normalize_req_http_options(),
      base_llm_opts:
        opts |> Keyword.get(:llm_opts, []) |> normalize_llm_opts(provider_opt_keys_by_string),
      provider_opt_keys_by_string: provider_opt_keys_by_string
    }
  end

  defp resolve_model_spec(:auto) do
    # :auto is a routing marker, not a Jido.AI alias. Resolve to system default.
    # The actual per-request model is resolved by Preflight's AutoRouter.
    Magus.Agents.Routing.ModelKeyResolver.default_model_key(:chat)
  end

  defp resolve_model_spec(model) when is_atom(model), do: Jido.AI.resolve_model(model)
  defp resolve_model_spec(model) when is_binary(model), do: model

  defp validate_request_policy!(:reject), do: :reject

  defp validate_request_policy!(other) do
    raise ArgumentError,
          "unsupported request_policy #{inspect(other)} for ReAct; supported values: [:reject]"
  end

  defp normalize_run_model(model) when is_atom(model) and not is_nil(model),
    do: resolve_model_spec(model)

  defp normalize_run_model(model) when is_binary(model) and model != "",
    do: resolve_model_spec(model)

  defp normalize_run_model(_), do: nil

  defp normalize_run_model_name(model_name) when is_binary(model_name) and model_name != "",
    do: model_name

  defp normalize_run_model_name(_), do: nil

  defp normalize_run_max_iterations(value) when is_integer(value) and value > 0, do: value
  defp normalize_run_max_iterations(_), do: nil

  defp normalize_run_system_prompt(value) when is_binary(value) and value != "", do: value
  defp normalize_run_system_prompt(_), do: nil

  defp normalize_run_tools(tools) when is_map(tools) do
    tools
    |> Map.values()
    |> normalize_run_tools()
  end

  defp normalize_run_tools(tools) when is_list(tools) do
    normalized =
      tools
      |> Enum.filter(fn
        module when is_atom(module) ->
          Code.ensure_loaded?(module) and function_exported?(module, :name, 0)

        _ ->
          false
      end)
      |> Enum.uniq()

    if normalized == [], do: nil, else: normalized
  end

  defp normalize_run_tools(_), do: nil

  defp normalize_runtime_max_iterations(value, _config) when is_integer(value) and value > 0,
    do: value

  defp normalize_runtime_max_iterations(_value, config), do: config[:max_iterations]

  defp normalize_map_opt(%{} = value), do: value
  defp normalize_map_opt({:%{}, _meta, pairs}) when is_list(pairs), do: Map.new(pairs)
  defp normalize_map_opt(_), do: %{}

  defp normalize_req_http_options(req_http_options) when is_list(req_http_options),
    do: req_http_options

  defp normalize_req_http_options(_), do: []

  defp normalize_llm_opts(llm_opts, provider_opt_keys_by_string) when is_list(llm_opts) do
    normalize_llm_opt_pairs(llm_opts, provider_opt_keys_by_string)
  end

  defp normalize_llm_opts(llm_opts, provider_opt_keys_by_string) when is_map(llm_opts) do
    llm_opts
    |> Enum.map(fn {key, value} ->
      normalized_key = normalize_llm_opt_key(key)

      normalized_value =
        normalize_llm_opt_value(normalized_key, value, provider_opt_keys_by_string)

      {normalized_key, normalized_value}
    end)
    |> normalize_llm_opt_pairs(provider_opt_keys_by_string)
  end

  defp normalize_llm_opts(_llm_opts, _provider_opt_keys_by_string), do: []

  defp normalize_llm_opt_pairs(pairs, provider_opt_keys_by_string) when is_list(pairs) do
    pairs
    |> Enum.reduce([], fn
      {key, value}, acc
      when is_atom(key) and not is_nil(key) and key not in @reserved_llm_opt_keys ->
        normalized_value = normalize_llm_opt_value(key, value, provider_opt_keys_by_string)
        [{key, normalized_value} | acc]

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_llm_opt_key(key) when is_atom(key), do: key

  defp normalize_llm_opt_key(key) when is_binary(key) do
    Map.get(@reqllm_generation_opt_keys_by_string, key) || maybe_to_existing_atom(key)
  end

  defp normalize_llm_opt_key(_), do: nil

  defp normalize_llm_opt_value(:provider_options, value, provider_opt_keys_by_string) do
    normalize_provider_options(value, provider_opt_keys_by_string)
  end

  defp normalize_llm_opt_value(_key, value, _provider_opt_keys_by_string), do: value

  defp normalize_provider_options(value, provider_opt_keys_by_string) when is_list(value) do
    normalize_provider_option_pairs(value, provider_opt_keys_by_string)
  end

  defp normalize_provider_options(value, provider_opt_keys_by_string) when is_map(value) do
    value
    |> Enum.map(fn {key, entry_value} ->
      {normalize_provider_opt_key(key, provider_opt_keys_by_string), entry_value}
    end)
    |> normalize_provider_option_pairs(provider_opt_keys_by_string)
  end

  defp normalize_provider_options(value, _provider_opt_keys_by_string), do: value

  defp normalize_provider_option_pairs(pairs, _provider_opt_keys_by_string) do
    pairs
    |> Enum.reduce([], fn
      {key, value}, acc when is_atom(key) and not is_nil(key) ->
        [{key, value} | acc]

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp normalize_provider_opt_key(key, _provider_opt_keys_by_string) when is_atom(key), do: key

  defp normalize_provider_opt_key(key, provider_opt_keys_by_string) when is_binary(key) do
    Map.get(provider_opt_keys_by_string, key) || maybe_to_existing_atom(key)
  end

  defp normalize_provider_opt_key(_key, _provider_opt_keys_by_string), do: nil

  defp maybe_to_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp provider_opt_keys_by_string(model_spec) when is_binary(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_mod} <- ReqLLM.provider(model.provider),
         true <- function_exported?(provider_mod, :provider_schema, 0) do
      provider_mod.provider_schema().schema
      |> Keyword.keys()
      |> Enum.map(&{Atom.to_string(&1), &1})
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp generate_call_id, do: "req_#{Jido.Util.generate_id()}"

  defp put_strategy_state(%Agent{} = agent, state) when is_map(state) do
    %{agent | state: Map.put(agent.state, StratState.key(), state)}
  end

  @doc """
  Returns the list of currently registered tools for the given agent.
  """
  @spec list_tools(Agent.t()) :: [module()]
  def list_tools(%Agent{} = agent) do
    state = StratState.get(agent, %{})
    config = state[:config] || %{}
    config[:tools] || []
  end
end
