defmodule Magus.Agents.Strategies.ReactStrategy.Runner do
  @moduledoc """
  Task-based ReAct runner.

  Produces a lazy event stream via `Stream.resource/3` and does not persist runtime
  state outside of caller-owned checkpoint tokens.
  """

  alias Jido.AI.Reasoning.ReAct.{Config, Event, PendingToolCall, State, Token}
  alias Jido.AI.{Thread, Turn}
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Agents.Support.ToolCallText
  alias Magus.Agents.Support.ToolsHelper

  require Logger

  @html_entities %{
    "&amp;" => "&",
    "&lt;" => "<",
    "&gt;" => ">",
    "&quot;" => "\"",
    "&#39;" => "'",
    "&apos;" => "'"
  }
  @type stream_opt ::
          {:request_id, String.t()}
          | {:run_id, String.t()}
          | {:state, State.t()}
          | {:task_supervisor, pid() | atom()}
          | {:context, map()}

  @doc """
  Starts a new ReAct coordinator task and returns a lazy event stream.
  """
  @spec stream(String.t(), Config.t(), [stream_opt()]) :: Enumerable.t()
  def stream(query, %Config{} = config, opts \\ []) when is_binary(query) do
    initial_state =
      case Keyword.get(opts, :state) do
        %State{} = state -> state
        _ -> State.new(query, config.system_prompt, request_id_opts(opts))
      end

    build_stream(initial_state, config, Keyword.put(opts, :query, query), emit_start?: true)
  end

  @doc """
  Continues a ReAct run from an existing runtime state.
  """
  @spec stream_from_state(State.t(), Config.t(), [stream_opt()]) :: Enumerable.t()
  def stream_from_state(%State{} = state, %Config{} = config, opts \\ []) do
    query = Keyword.get(opts, :query)
    has_initial_messages = match?([_ | _], Keyword.get(opts, :initial_messages))

    state =
      case query do
        # Skip appending query to thread when initial_messages are present —
        # they already contain the current user message from the context Builder.
        q when is_binary(q) and q != "" and not has_initial_messages ->
          append_query(state, q)

        _ ->
          state
      end

    build_stream(state, config, opts, emit_start?: false)
  end

  defp build_stream(%State{} = initial_state, %Config{} = config, opts, stream_opts) do
    owner = self()
    ref = make_ref()

    case start_task(
           fn -> coordinator(owner, ref, initial_state, config, opts, stream_opts) end,
           opts
         ) do
      {:ok, pid} ->
        # Link the coordinator to the consuming process so a hard kill of the
        # consumer (worker hibernation, node drain) tears the coordinator down
        # instead of leaving a zombie turn running LLM calls into the void.
        # In-band coordinator failures never propagate here: coordinator/6
        # converts them to :request_failed events and exits :normal.
        Process.link(pid)
        monitor_ref = Process.monitor(pid)
        halt_ref = monitor_halt_pid(Keyword.get(opts, :halt_on_down))

        Stream.resource(
          fn ->
            %{
              done?: false,
              down?: false,
              cancel_sent?: false,
              pid: pid,
              monitor_ref: monitor_ref,
              halt_ref: halt_ref,
              ref: ref
            }
          end,
          &next_event(owner, &1),
          &cleanup(owner, &1)
        )

      {:error, reason} ->
        Stream.map([reason], fn error ->
          raise "Failed to start ReAct runner task: #{inspect(error)}"
        end)
    end
  end

  defp coordinator(owner, ref, state, config, opts, stream_opts) do
    # The coordinator runs in its own task process; Logger metadata is per-process
    # and not inherited from the spawning worker, so set request_id/run_id here so
    # every `[Runner]` log line for this turn is greppable by request.
    Logger.metadata(request_id: state.request_id, run_id: state.run_id)
    initial_messages = Keyword.get(opts, :initial_messages)

    context =
      opts
      |> Keyword.get(:context, %{})
      |> maybe_put_initial_messages_in_context(initial_messages)

    state =
      case stream_opts[:emit_start?] do
        true ->
          {state, _} =
            emit_event(state, owner, ref, :request_started, %{
              query: latest_query(state),
              config_fingerprint: Config.fingerprint(config)
            })

          state

        _ ->
          state
      end

    try do
      state
      |> run_loop(owner, ref, config, context)
      |> finalize(owner, ref, config)
    catch
      {:cancelled, %State{} = current_state, reason} ->
        cancelled_state =
          current_state
          |> State.put_status(:cancelled)
          |> State.put_result("Request cancelled (reason: #{inspect(reason)})")

        {cancelled_state, _} =
          emit_event(cancelled_state, owner, ref, :request_cancelled, %{reason: reason})

        {_cancelled_state, _token} =
          emit_checkpoint(cancelled_state, owner, ref, config, :terminal)

        send(owner, {:react_runner, ref, :done})

      kind, reason ->
        failed_state =
          state
          |> State.put_status(:failed)
          |> State.put_error(%{kind: kind, reason: inspect(reason)})

        {failed_state, _} =
          emit_event(failed_state, owner, ref, :request_failed, %{
            error: %{kind: kind, reason: inspect(reason)},
            error_type: :runtime
          })

        {_failed_state, _token} = emit_checkpoint(failed_state, owner, ref, config, :terminal)
        send(owner, {:react_runner, ref, :done})
    end
  end

  defp run_loop(%State{} = state, owner, ref, %Config{} = config, context) do
    check_cancel!(state, ref)

    cond do
      state.status in [:completed, :failed, :cancelled] ->
        state

      state.status == :awaiting_tools and state.pending_tool_calls != [] ->
        {state, config, context} = run_pending_tool_round(state, owner, ref, config, context)
        run_loop(state, owner, ref, config, context)

      # TODO: Better handling -> give LLMs a heads up that they exceeded maximum iterations.
      state.iteration > config.max_iterations ->
        state
        |> State.put_status(:completed)
        |> State.put_result("Maximum iterations reached without a final answer.")
        |> then(fn completed ->
          {completed, _} =
            emit_event(completed, owner, ref, :request_completed, %{
              result: completed.result,
              termination_reason: :max_iterations,
              usage: completed.usage
            })

          completed
        end)

      true ->
        case run_llm_step(state, owner, ref, config, context) do
          {:final_answer, state} ->
            state

          {:tool_calls, state, tool_calls} ->
            {state, config, context} =
              run_tool_round(state, owner, ref, config, context, tool_calls)

            run_loop(state, owner, ref, config, context)

          {:error, state, reason, error_type} ->
            state
            |> State.put_status(:failed)
            |> State.put_error(reason)
            |> then(fn failed ->
              {failed, _} =
                emit_event(failed, owner, ref, :request_failed, %{
                  error: reason,
                  error_type: error_type
                })

              failed
            end)
        end
    end
  end

  defp run_llm_step(%State{} = state, owner, ref, %Config{} = config, context) do
    check_cancel!(state, ref)
    state = drain_steering!(state, ref)

    call_id = "call_#{state.run_id}_#{state.iteration}_#{Jido.Util.generate_id()}"
    state = State.put_llm_call_id(state, call_id)

    {state, _} =
      emit_event(
        state,
        owner,
        ref,
        :llm_started,
        %{
          call_id: call_id,
          model: config.model,
          message_count:
            Thread.length(state.thread) +
              case state.thread.system_prompt do
                nil -> 0
                _ -> 1
              end
        },
        llm_call_id: call_id
      )

    thread_messages = Thread.to_messages(state.thread)

    # When initial_messages are present (from Builder with full conversation history
    # and images), interleave them with the thread's system prompt and agentic-loop
    # messages. The system prompt must come first so the LLM follows it consistently.
    messages =
      case context do
        %{initial_messages: msgs} when is_list(msgs) and msgs != [] ->
          {system_msgs, loop_msgs} =
            Enum.split_with(thread_messages, &(Map.get(&1, :role) == :system))

          system_msgs ++ msgs ++ loop_msgs

        _ ->
          thread_messages
      end

    if state.iteration == 1 do
      Logger.debug(fn ->
        msg_summary =
          Enum.map(messages, fn msg ->
            role = Map.get(msg, :role) || Map.get(msg, "role")
            tool_calls = Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls")
            tool_call_id = Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id")

            content =
              case Map.get(msg, :content) || Map.get(msg, "content") do
                c when is_binary(c) -> String.slice(c, 0, 80)
                parts when is_list(parts) -> "#{length(parts)} part(s)"
                _ -> "?"
              end

            tc_info =
              cond do
                is_list(tool_calls) and tool_calls != [] ->
                  " tool_calls=#{length(tool_calls)}"

                is_binary(tool_call_id) and tool_call_id != "" ->
                  " tool_call_id=#{tool_call_id}"

                true ->
                  ""
              end

            "  #{role}: #{content}#{tc_info}"
          end)

        "[Runner] Initial LLM context (#{length(messages)} msgs):\n" <>
          Enum.join(msg_summary, "\n")
      end)
    end

    llm_opts =
      config
      |> Config.llm_opts()
      |> normalize_tool_choice()
      |> append_mcp_tools(context)

    llm_started_at = System.monotonic_time(:millisecond)

    case request_turn(state, owner, ref, config, messages, llm_opts) do
      {:ok, state, turn, extra} ->
        emit_llm_call_telemetry(config, state, turn, extra, llm_started_at)
        state = State.merge_usage(state, turn.usage)

        # TODO(autonomy/task-11): Enforce CustomAgent.max_tokens_per_run as a
        # ReAct stop condition. Use Magus.Agents.Strategies.React.TokenAccumulator
        # to compare cumulative usage against the cap (cap source: AgentRun's
        # target CustomAgent). On {:stop_budget_exceeded, _}:
        #
        #   1. Emit a new `:request_budget_exceeded` event so plugins can mark
        #      the AgentRun as :budget_exceeded (status enum was extended in
        #      this task) and persist a fixed "(stopped: token cap reached)"
        #      final message — without another LLM call.
        #   2. Halt the loop instead of recursing into run_loop/5.
        #
        # The cap and accumulator state need to ride alongside `State` (likely
        # via the runner's `context` map plumbed in build_stream/4) to stay out
        # of the upstream Jido struct. See test/magus/agents/strategies/react/
        # token_accumulator_test.exs for helper semantics.

        {state, _} =
          emit_event(
            state,
            owner,
            ref,
            :llm_completed,
            %{
              call_id: call_id,
              turn_type: turn.type,
              text: turn.text,
              thinking_content: turn.thinking_content,
              tool_calls: turn.tool_calls,
              usage: turn.usage,
              citations: Map.get(extra, :citations, []),
              generation_id: Map.get(extra, :generation_id)
            },
            llm_call_id: call_id
          )

        state =
          Thread.append_assistant(
            state.thread,
            turn.text,
            case turn.type do
              :tool_calls -> to_reqllm_tool_calls(turn.tool_calls)
              _ -> nil
            end,
            maybe_thinking_opt(turn.thinking_content)
          )
          |> then(&%{state | thread: &1})

        {state, _token} = emit_checkpoint(state, owner, ref, config, :after_llm)

        case Turn.needs_tools?(turn) do
          true ->
            {:tool_calls, State.put_status(state, :awaiting_tools), turn.tool_calls}

          _ ->
            completed =
              state
              |> State.put_status(:completed)
              |> State.put_result(turn.text)

            {completed, _} =
              emit_event(completed, owner, ref, :request_completed, %{
                result: turn.text,
                termination_reason: :final_answer,
                usage: completed.usage
              })

            {:final_answer, completed}
        end

      {:error, state, reason, error_type} ->
        emit_llm_call_failure_telemetry(config, state, reason, error_type, llm_started_at)
        {:error, state, reason, error_type}
    end
  end

  defp request_turn(%State{} = state, owner, ref, %Config{} = config, messages, llm_opts) do
    request_turn(state, owner, ref, config, messages, llm_opts, 0)
  end

  # Re-asks the LLM when it returns a blank final answer (no text + no tool
  # calls). This is the most common cause of "empty assistant messages":
  # certain models (notably Anthropic Sonnet via OpenRouter) intermittently
  # end a turn with only reasoning, or with nothing at all. Bounded by
  # `:empty_response_max_retries` with an exponential backoff so a model that
  # is genuinely silent eventually surfaces rather than looping forever.
  defp request_turn(%State{} = state, owner, ref, %Config{} = config, messages, llm_opts, attempt) do
    result =
      case config.streaming do
        false ->
          request_turn_generate(state, config, messages, llm_opts)

        _ ->
          request_turn_stream(state, owner, ref, config, messages, llm_opts)
      end

    max_retries = empty_response_max_retries()

    case result do
      {:ok, next_state, %Turn{} = turn, _extra} when attempt < max_retries ->
        if blank_final_answer?(turn) do
          Logger.warning(
            "[Runner] Blank final answer from #{inspect(config.model)} " <>
              "(attempt #{attempt + 1}/#{max_retries + 1}); re-asking the LLM"
          )

          empty_response_backoff(attempt)
          request_turn(next_state, owner, ref, config, messages, llm_opts, attempt + 1)
        else
          tag_empty_retries(result, attempt)
        end

      _ ->
        tag_empty_retries(result, attempt)
    end
  end

  # Records how many blank-answer re-asks preceded a successful turn so the LLM
  # call telemetry can report `empty_retries` (the recurrence signal). Only the
  # `{:ok, ...}` shape carries an extra-metadata map; errors pass through.
  defp tag_empty_retries({:ok, state, turn, extra}, attempt) when is_map(extra) do
    {:ok, state, turn, Map.put(extra, :empty_retries, attempt)}
  end

  defp tag_empty_retries(result, _attempt), do: result

  # A final-answer turn carrying no usable text and no tool calls. Strips the
  # pseudo tool-call payload first so a turn that is *only* an unparsed
  # `<tool_calls>` blob (i.e. effectively empty) is also treated as blank.
  defp blank_final_answer?(%Turn{type: :final_answer} = turn) do
    blank_text?(turn.text) and (turn.tool_calls == nil or turn.tool_calls == [])
  end

  defp blank_final_answer?(_), do: false

  defp blank_text?(text) when is_binary(text) do
    text
    |> ToolCallText.strip_pseudo_tool_payload()
    |> String.trim() == ""
  end

  defp blank_text?(_), do: true

  defp empty_response_max_retries do
    :magus
    |> Application.get_env(:agents, [])
    |> Keyword.get(:empty_response_max_retries, 3)
    |> normalize_retry_count()
  end

  defp empty_response_backoff(attempt) do
    base =
      :magus
      |> Application.get_env(:agents, [])
      |> Keyword.get(:empty_response_retry_backoff_ms, 500)
      |> normalize_backoff()

    if base > 0 do
      Process.sleep(base * trunc(:math.pow(2, attempt)))
    end
  end

  defp llm_stream_timeout_ms do
    :magus
    |> Application.get_env(:agents, [])
    |> Keyword.get(:llm_stream_timeout_ms, 300_000)
    |> normalize_timeout()
  end

  # ---------------------------------------------------------------------------
  # LLM call telemetry — emits one `[:magus, :agents, :llm, :call]` event per
  # logical LLM turn (including any blank-answer re-asks) so latency, tokens,
  # finish reason, and empty turns are measurable. Surfaced in the LiveDashboard
  # at /admin/telemetry via metrics registered in MagusWeb.Telemetry.
  # ---------------------------------------------------------------------------
  defp emit_llm_call_telemetry(
         %Config{} = config,
         %State{} = state,
         %Turn{} = turn,
         extra,
         started_at
       ) do
    usage = turn.usage || %{}
    prompt_tokens = usage_int(usage, :input_tokens, 0)
    completion_tokens = usage_int(usage, :output_tokens, 0)
    total_tokens = usage_int(usage, :total_tokens, prompt_tokens + completion_tokens)
    empty? = blank_final_answer?(turn)

    measurements =
      %{
        duration: System.monotonic_time(:millisecond) - started_at,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        empty_retries: Map.get(extra, :empty_retries, 0)
      }
      |> maybe_put(:ttft, Map.get(extra, :ttft_ms))

    Magus.Telemetry.llm_call(measurements, %{
      model: model_label(config.model),
      finish_reason: turn_finish_reason(turn, empty?),
      empty?: empty?,
      streaming: config.streaming != false,
      success: true,
      request_id: state.request_id,
      run_id: state.run_id
    })
  end

  defp emit_llm_call_failure_telemetry(
         %Config{} = config,
         %State{} = state,
         reason,
         error_type,
         started_at
       ) do
    Magus.Telemetry.llm_call(
      %{
        duration: System.monotonic_time(:millisecond) - started_at,
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0,
        empty_retries: 0
      },
      %{
        model: model_label(config.model),
        finish_reason: failure_finish_reason(reason, error_type),
        empty?: true,
        streaming: config.streaming != false,
        success: false,
        request_id: state.request_id,
        run_id: state.run_id
      }
    )
  end

  defp turn_finish_reason(%Turn{type: :tool_calls}, _empty?), do: "tool_calls"
  defp turn_finish_reason(%Turn{}, true), do: "empty"
  defp turn_finish_reason(%Turn{}, false), do: "stop"

  defp failure_finish_reason(%{type: type}, _error_type) when is_atom(type) and not is_nil(type),
    do: to_string(type)

  defp failure_finish_reason(_reason, error_type), do: to_string(error_type)

  defp usage_int(usage, key, default) when is_map(usage) do
    case Map.get(usage, key) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  defp usage_int(_usage, _key, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp model_label(model) when is_binary(model), do: model
  defp model_label(%{model: model}) when is_binary(model), do: model
  defp model_label(model), do: inspect(model)

  defp request_turn_stream(%State{} = state, owner, ref, %Config{} = config, messages, llm_opts) do
    case LLMClient.llm_client().stream_text(config.model, messages, llm_opts) do
      {:ok, stream_response} ->
        case consume_stream(state, owner, ref, config, stream_response) do
          {:ok, updated_state, turn, extra} -> {:ok, updated_state, turn, extra}
          {:error, updated_state, reason} -> {:error, updated_state, reason, :llm_stream}
        end

      {:error, reason} ->
        {:error, state, reason, :llm_request}
    end
  end

  defp request_turn_generate(%State{} = state, %Config{} = config, messages, llm_opts) do
    case LLMClient.llm_client().generate_text(config.model, messages, llm_opts) do
      {:ok, response} ->
        consume_generate(state, config, response)

      {:error, reason} ->
        {:error, state, reason, :llm_request}
    end
  end

  defp consume_stream(%State{} = state, owner, ref, %Config{} = config, stream_response) do
    check_cancel!(state, ref)

    trace_cfg = config.trace
    stream_started_at = System.monotonic_time(:millisecond)
    deadline = stream_started_at + llm_stream_timeout_ms()

    acc =
      Enum.reduce_while(
        stream_response.stream,
        %{
          chunks: [],
          state: state,
          tool_call_signaled: false,
          timed_out: false,
          first_chunk_at: nil
        },
        fn chunk, %{state: current} = acc ->
          check_cancel!(current, ref)

          if System.monotonic_time(:millisecond) > deadline do
            {:halt, %{acc | timed_out: true}}
          else
            {current, tool_call_signaled} =
              maybe_signal_tool_call_start(
                current,
                owner,
                ref,
                chunk,
                trace_cfg,
                acc.tool_call_signaled
              )

            current = maybe_emit_chunk_delta(current, owner, ref, chunk, trace_cfg)

            {:cont,
             %{
               acc
               | chunks: [chunk | acc.chunks],
                 state: current,
                 tool_call_signaled: tool_call_signaled,
                 first_chunk_at: acc.first_chunk_at || System.monotonic_time(:millisecond)
             }}
          end
        end
      )

    if acc.timed_out do
      Logger.error(
        "[Runner] LLM stream for #{inspect(config.model)} exceeded " <>
          "#{llm_stream_timeout_ms()}ms wall-clock; aborting turn"
      )

      {:error, acc.state, %{error: "LLM stream timed out", type: :timeout}}
    else
      chunks = Enum.reverse(acc.chunks)
      summary = ReqLLM.Response.Stream.summarize(chunks)
      tool_calls = ToolsHelper.extract_tool_calls_from_chunks(chunks)

      turn_type =
        case tool_calls do
          tcs when is_list(tcs) and tcs != [] -> :tool_calls
          _ -> :final_answer
        end

      # Extract citations from meta chunks (e.g. Perplexity Sonar models)
      citations = extract_citations_from_chunks(chunks)

      turn =
        Turn.from_result_map(%{
          type: turn_type,
          text: summary.text,
          thinking_content: normalize_blank(summary.thinking),
          tool_calls: tool_calls,
          usage: ReqLLM.StreamResponse.usage(stream_response) || summary.usage,
          model: config.model
        })

      # Attach citations + the provider generation id (for usage reconciliation)
      # and the time-to-first-token (ms) as extra metadata alongside the turn.
      ttft_ms = if acc.first_chunk_at, do: acc.first_chunk_at - stream_started_at

      {:ok, acc.state, turn,
       %{
         citations: citations,
         generation_id: stream_provider_id(stream_response),
         ttft_ms: ttft_ms
       }}
    end
  rescue
    e ->
      {:error, state, %{error: Exception.message(e), type: e.__struct__}}
  end

  # Read the provider's generation id (OpenRouter "gen-...") from the stream when
  # the patched req_llm exposes it. Defensive: returns nil on stock req_llm so the
  # build works and usage reconciliation simply stays dormant. Shares the already
  # awaited metadata handle with usage/1, so this adds no extra blocking.
  defp stream_provider_id(stream_response) do
    # apply/3 (not a direct call) so this compiles warning-free against stock
    # req_llm — the patched provider_id/1 may be absent until the fork is wired.
    if function_exported?(ReqLLM.StreamResponse, :provider_id, 1) do
      apply(ReqLLM.StreamResponse, :provider_id, [stream_response])
    end
  rescue
    _ -> nil
  end

  defp consume_generate(%State{} = state, %Config{} = config, response) do
    turn = Turn.from_response(response, model: config.model)
    {:ok, state, turn, %{citations: []}}
  rescue
    e ->
      {:error, state, %{error: Exception.message(e), type: e.__struct__}, :llm_response}
  end

  defp fetch_field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  # OpenRouter's translate_tool_choice_format assumes tool_choice is nil or a map.
  # Atom/string values like :auto / "auto" crash it. Since "auto" is the default
  # when tools are present, just drop it. Only keep map values (forced tool choice).
  defp normalize_tool_choice(opts) do
    case Keyword.get(opts, :tool_choice) do
      %{} = _map -> opts
      _ -> Keyword.delete(opts, :tool_choice)
    end
  end

  defp maybe_emit_chunk_delta(
         %State{} = state,
         owner,
         ref,
         %ReqLLM.StreamChunk{type: :content, text: text},
         trace_cfg
       )
       when is_binary(text) and text != "" do
    case trace_cfg[:capture_deltas?] do
      true ->
        {state, _} =
          emit_event(state, owner, ref, :llm_delta, %{chunk_type: :content, delta: text})

        state

      _ ->
        state
    end
  end

  defp maybe_emit_chunk_delta(
         %State{} = state,
         owner,
         ref,
         %ReqLLM.StreamChunk{type: :thinking, text: text},
         trace_cfg
       )
       when is_binary(text) and text != "" do
    case trace_cfg[:capture_deltas?] do
      true ->
        {state, _} =
          emit_event(state, owner, ref, :llm_delta, %{chunk_type: :thinking, delta: text})

        state

      _ ->
        state
    end
  end

  defp maybe_emit_chunk_delta(%State{} = state, _owner, _ref, _chunk, _trace_cfg), do: state

  # Extract citations from meta chunks (e.g. Perplexity Sonar via OpenRouterWithCitations).
  # Returns the last non-empty citations list found, or [].
  defp extract_citations_from_chunks(chunks) do
    Enum.reduce(chunks, [], fn
      %ReqLLM.StreamChunk{type: :meta, metadata: %{citations: citations}}, _acc
      when is_list(citations) and citations != [] ->
        citations

      _, acc ->
        acc
    end)
  end

  # Emit a single :llm_delta event with chunk_type: :tool_call when the first
  # tool_call chunk arrives. This lets the UI show a thinking indicator during
  # tool-call argument streaming (which can be long for document generation).
  defp maybe_signal_tool_call_start(
         %State{} = state,
         owner,
         ref,
         %ReqLLM.StreamChunk{type: :tool_call},
         trace_cfg,
         _signaled = false
       ) do
    case trace_cfg[:capture_deltas?] do
      true ->
        {state, _} =
          emit_event(state, owner, ref, :llm_delta, %{chunk_type: :tool_call, delta: ""})

        {state, true}

      _ ->
        {state, true}
    end
  end

  defp maybe_signal_tool_call_start(%State{} = state, _owner, _ref, _chunk, _trace_cfg, signaled),
    do: {state, signaled}

  defp run_tool_round(%State{} = state, owner, ref, %Config{} = config, context, tool_calls)
       when is_list(tool_calls) do
    pending = Enum.map(tool_calls, &PendingToolCall.from_tool_call/1)
    state = State.put_pending_tools(state, pending)

    {state, _} =
      Enum.reduce(pending, {state, nil}, fn pending_call, {acc, _} ->
        emit_event(
          acc,
          owner,
          ref,
          :tool_started,
          %{
            tool_call_id: pending_call.id,
            tool_name: pending_call.name,
            arguments: maybe_redact_args(pending_call.arguments, config)
          },
          tool_call_id: pending_call.id,
          tool_name: pending_call.name
        )
      end)

    results =
      pending
      |> Task.async_stream(
        fn call -> execute_tool_with_retries(call, config, context) end,
        ordered: true,
        max_concurrency: config.tool_exec.concurrency,
        timeout: :infinity
      )
      |> Enum.zip(pending)
      |> Enum.map(fn
        {{:ok, result}, _call} ->
          result

        {{:exit, reason}, call} ->
          error = {:error, %{type: :task_exit, reason: inspect(reason)}}
          {call, error, 1, 0}
      end)

    {state, thread} =
      Enum.reduce(results, {state, state.thread}, fn
        {pending_call, result, attempts, duration_ms}, {acc, thread_acc} ->
          completed = PendingToolCall.complete(pending_call, result, attempts, duration_ms)

          {acc, _} =
            emit_event(
              acc,
              owner,
              ref,
              :tool_completed,
              %{
                tool_call_id: completed.id,
                tool_name: completed.name,
                result: result,
                attempts: attempts,
                duration_ms: duration_ms
              },
              tool_call_id: completed.id,
              tool_name: completed.name
            )

          clean_result = strip_internal_keys(result)
          content = Turn.format_tool_result_content(clean_result)

          thread_acc =
            Thread.append_tool_result(thread_acc, completed.id, completed.name, content)

          {acc, thread_acc}
      end)

    config = maybe_register_new_tools(results, config)
    context = maybe_register_new_mcp_tools(results, context)

    state =
      state
      |> State.put_status(:running)
      |> State.clear_pending_tools()
      |> State.inc_iteration()
      |> Map.put(:thread, thread)

    {state, _token} = emit_checkpoint(state, owner, ref, config, :after_tools)
    {state, config, context}
  end

  defp run_pending_tool_round(%State{} = state, owner, ref, %Config{} = config, context) do
    run_tool_round(
      State.put_status(state, :awaiting_tools),
      owner,
      ref,
      config,
      context,
      Enum.map(state.pending_tool_calls, fn
        %PendingToolCall{} = call -> %{id: call.id, name: call.name, arguments: call.arguments}
        %{} = call -> call
      end)
    )
  end

  # Collect __new_tools__ from successful tool results and merge into config.tools.
  defp maybe_register_new_tools(results, %Config{} = config) do
    new_modules =
      results
      |> Enum.flat_map(fn
        {_call, {:ok, %{__new_tools__: modules}}, _attempts, _dur} when is_list(modules) ->
          modules

        _ ->
          []
      end)
      |> Enum.uniq()

    case new_modules do
      [] ->
        config

      modules ->
        new_tools_map =
          Enum.reduce(modules, config.tools, fn mod, acc ->
            Map.put_new(acc, mod.name(), mod)
          end)

        %{config | tools: new_tools_map}
    end
  end

  # --- MCP tool carrier helpers ---------------------------------------------
  #
  # The MCP carrier lives ONLY in the Magus-owned `context` map under
  # `:__mcp_tools__` (never on the vendored %Config{}/%State{}). Each entry:
  #   %{coined_name: String.t(), tool: %ReqLLM.Tool{}, server_id: String.t(),
  #     remote_name: String.t()}

  @doc false
  def append_mcp_tools(opts, context) do
    case mcp_tools_list(context) do
      [] ->
        opts

      entries ->
        # Defensive: reject any malformed carrier entry that lacks a tool so a
        # nil can never be injected into the LLM :tools list.
        structs = entries |> Enum.map(& &1.tool) |> Enum.reject(&is_nil/1)
        Keyword.update(opts, :tools, structs, fn existing -> existing ++ structs end)
    end
  end

  defp mcp_tools_list(context) when is_map(context) do
    case Map.get(context, :__mcp_tools__) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp mcp_tools_list(_), do: []

  @doc false
  def mcp_tool_entry(context, name) do
    context
    |> mcp_tools_list()
    |> Enum.find(fn e -> e.coined_name == name end)
  end

  # Collect __new_mcp_tools__ (carrier entries) from successful results and
  # merge into context[:__mcp_tools__], dedup by coined_name. This makes a
  # mid-turn load_tool of an MCP tool callable on the next LLM step (mirrors
  # how maybe_register_new_tools updates config.tools).
  defp maybe_register_new_mcp_tools(results, context) do
    new_entries =
      results
      |> Enum.flat_map(fn
        {_call, {:ok, %{__new_mcp_tools__: entries}}, _attempts, _dur} when is_list(entries) ->
          entries

        _ ->
          []
      end)

    case new_entries do
      [] ->
        context

      entries ->
        existing = mcp_tools_list(context)
        merged = Enum.uniq_by(existing ++ entries, & &1.coined_name)
        Map.put(context, :__mcp_tools__, merged)
    end
  end

  # Strip internal keys (e.g. __new_tools__, __new_mcp_tools__, __attachments__)
  # so the LLM doesn't see module atoms or side-channel payloads used by plugins.
  defp strip_internal_keys({:ok, result}) when is_map(result) do
    {:ok, Map.drop(result, [:__new_tools__, :__new_mcp_tools__, :__attachments__])}
  end

  defp strip_internal_keys(other), do: other

  defp execute_tool_with_retries(%PendingToolCall{} = pending_call, %Config{} = config, context) do
    if parse_error_arguments?(pending_call.arguments) do
      {
        pending_call,
        {:error,
         %{
           type: :parse_error,
           message: "Tool call arguments could not be parsed as JSON"
         }},
        1,
        0
      }
    else
      case mcp_tool_entry(context, pending_call.name) do
        %{server_id: server_id, remote_name: remote_name} ->
          execute_mcp_tool(pending_call, server_id, remote_name, context)

        _ ->
          module = Map.get(config.tools, pending_call.name)

          case is_atom(module) and function_exported?(module, :name, 0) and
                 function_exported?(module, :run, 2) do
            true ->
              do_execute_tool_with_retries(pending_call, module, config, context, 1)

            _ ->
              message = build_unknown_tool_message(pending_call.name, config.tools)
              {pending_call, {:error, %{type: :unknown_tool, message: message}}, 1, 0}
          end
      end
    end
  end

  @doc false
  # Resolve the MCP actor id from the runtime context: the ACTING user (message
  # author, threaded in via the base tool context) when present, falling back to
  # the conversation owner (`user_id`). MCP-only: non-MCP tools still act as the
  # owner via `context[:user]`/`[:user_id]`.
  def mcp_acting_user_id(context) when is_map(context) do
    context[:acting_user_id] || context["acting_user_id"] || context[:user_id] ||
      context["user_id"]
  end

  # Dispatch an MCP tool through the Executor. The carrier-provided server_id is
  # re-fetched WITH the actor at call time, re-validating access (a user who lost
  # access mid-turn gets the soft error, not a crash). Executor.call/4 always
  # returns {:ok, map}. Returns the runner's 4-tuple result shape.
  #
  # The actor is the ACTING user (with owner fallback), so credential resolution
  # in the Executor picks the acting user's credential, and access re-validation
  # cannot grant the author access the author lacks.
  defp execute_mcp_tool(%PendingToolCall{} = pending_call, server_id, remote_name, context) do
    actor =
      Magus.Agents.Tools.Search.ActorContext.from(%{
        user_id: mcp_acting_user_id(context),
        conversation_id: context[:conversation_id]
      }).user

    result =
      if is_nil(actor) do
        {:ok, %{error: "MCP server no longer accessible. Call tool_search again."}}
      else
        case Magus.MCP.get_server(server_id, actor: actor) do
          {:ok, server} ->
            args = decode_html_entities(pending_call.arguments)
            # Hand the executor the resolved actor (guaranteed loaded %User{} or
            # nil), not the raw context[:user] which may be an %Ash.NotLoaded{}.
            Magus.MCP.Executor.call(server, remote_name, args, Map.put(context, :user, actor))

          _ ->
            {:ok, %{error: "MCP server no longer accessible. Call tool_search again."}}
        end
      end

    {pending_call, result, 1, 0}
  end

  defp build_unknown_tool_message(tool_name, loaded_tools) do
    base = "Tool '#{tool_name}' not found"

    with true <- Map.has_key?(loaded_tools, "load_skill"),
         [_ | _] = skills <- find_skills_providing_tool(tool_name) do
      "#{base}. #{format_skill_hint(skills)}"
    else
      _ -> base
    end
  end

  defp find_skills_providing_tool(tool_name) do
    Magus.Agents.Skills.Registry.list_skills()
    |> Enum.filter(fn skill -> tool_name in (skill.tools || []) end)
    |> Enum.map(& &1.name)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp format_skill_hint([skill]) do
    ~s(Hint: This tool is provided by the "#{skill}" skill. ) <>
      ~s(Call the load_skill tool with skill_name: "#{skill}" first, then retry.)
  end

  defp format_skill_hint(skills) do
    names = Enum.map_join(skills, ", ", &~s("#{&1}"))

    ~s(Hint: This tool is provided by one of these skills: #{names}. ) <>
      "Call the load_skill tool to load the appropriate one, then retry."
  end

  defp parse_error_arguments?(arguments) when is_map(arguments) do
    Map.get(arguments, "__parse_error__") == true || Map.get(arguments, :__parse_error__) == true
  end

  defp parse_error_arguments?(_), do: false

  defp do_execute_tool_with_retries(
         %PendingToolCall{} = pending_call,
         module,
         %Config{} = config,
         context,
         attempt
       ) do
    start_ms = System.monotonic_time(:millisecond)
    timeout_ms = tool_execution_timeout(module, config)

    base_tool_context = tool_context_for(context, pending_call.name)

    tool_context =
      base_tool_context
      |> Map.put(:__event_id__, pending_call.id)
      |> Map.put(:__tool_name__, pending_call.name)
      |> Map.put_new_lazy(:__conversation_id__, fn ->
        base_tool_context[:conversation_id] || base_tool_context["conversation_id"]
      end)

    normalized_arguments = decode_html_entities(pending_call.arguments)

    result =
      safe_execute_module(module, normalized_arguments, tool_context,
        timeout: timeout_ms,
        max_retries: 0
      )

    duration_ms = max(System.monotonic_time(:millisecond) - start_ms, 0)
    max_retries = normalize_retry_count(config.tool_exec[:max_retries])
    backoff_ms = normalize_backoff(config.tool_exec[:retry_backoff_ms])

    case retryable?(result) and attempt <= max_retries do
      true ->
        case backoff_ms > 0 do
          true -> Process.sleep(backoff_ms)
          _ -> :ok
        end

        do_execute_tool_with_retries(pending_call, module, config, context, attempt + 1)

      _ ->
        {pending_call, result, attempt, duration_ms}
    end
  end

  # Per-tool timeout override: a tool that legitimately runs long (e.g.
  # await_sub_agents polling sub-agent runs) exports execution_timeout_ms/0
  # returning a pos_integer or :infinity; everything else uses the run-level
  # tool timeout from config.
  defp tool_execution_timeout(module, %Config{} = config) do
    if function_exported?(module, :execution_timeout_ms, 0) do
      case module.execution_timeout_ms() do
        :infinity -> :infinity
        value when is_integer(value) and value > 0 -> value
        _ -> normalize_timeout(config.tool_exec[:timeout_ms])
      end
    else
      normalize_timeout(config.tool_exec[:timeout_ms])
    end
  end

  defp retryable?({:ok, _}), do: false

  defp retryable?({:error, %{type: :timeout}}), do: true
  defp retryable?({:error, %{type: :exception}}), do: true
  defp retryable?({:error, %{type: :execution_error}}), do: true
  defp retryable?({:error, _}), do: false

  defp finalize(%State{} = state, owner, ref, %Config{} = config) do
    {state, _token} = emit_checkpoint(state, owner, ref, config, :terminal)
    send(owner, {:react_runner, ref, :done})
    state
  end

  defp emit_checkpoint(%State{} = state, owner, ref, %Config{} = config, reason)
       when reason in [:after_llm, :after_tools, :terminal] do
    token = Token.issue(state, config)

    emit_event(state, owner, ref, :checkpoint, %{
      token: token,
      reason: reason
    })
    |> then(fn {updated, _event} -> {updated, token} end)
  end

  defp emit_event(%State{} = state, owner, ref, kind, data, extra \\ %{}) do
    {state, seq} = State.bump_seq(state)

    event =
      Event.new(%{
        seq: seq,
        run_id: state.run_id,
        request_id: state.request_id,
        iteration: state.iteration,
        kind: kind,
        llm_call_id: fetch_extra(extra, :llm_call_id, state.llm_call_id),
        tool_call_id: fetch_extra(extra, :tool_call_id),
        tool_name: fetch_extra(extra, :tool_name),
        data: data
      })

    send(owner, {:react_runner, ref, :event, event})
    {state, event}
  end

  defp next_event(_owner, %{done?: true} = state), do: {:halt, state}

  defp next_event(_owner, %{done?: false, down?: true, ref: ref} = state) do
    receive do
      {:react_stream_cancel, _reason} ->
        next_event(nil, state)

      {:react_runner, ^ref, :event, event} ->
        {[event], state}

      {:react_runner, ^ref, :done} ->
        {:halt, %{state | done?: true}}
    after
      0 ->
        {:halt, %{state | done?: true}}
    end
  end

  defp next_event(_owner, %{ref: ref} = state) do
    receive do
      {:react_stream_cancel, reason} ->
        next_event(nil, request_stream_cancel(state, reason))

      {:react_stream_steer, payload} ->
        next_event(nil, request_stream_steer(state, payload))

      {:react_runner, ^ref, :event, event} ->
        {[event], state}

      {:react_runner, ^ref, :done} ->
        {:halt, %{state | done?: true}}

      {:DOWN, monitor_ref, :process, _pid, _reason} when monitor_ref == state.monitor_ref ->
        next_event(nil, %{state | down?: true})

      # The watched pid (the worker agent) died: the events have no consumer
      # anymore, so halt. cleanup/2 then shuts the coordinator down.
      {:DOWN, halt_ref, :process, _pid, _reason} when halt_ref == state.halt_ref ->
        {:halt, %{state | done?: true}}
    end
  end

  defp cleanup(_owner, %{pid: pid, ref: ref, monitor_ref: monitor_ref} = state)
       when is_pid(pid) do
    demonitor_halt_ref(state)

    case Process.alive?(pid) do
      true ->
        send(pid, {:react_cancel, ref, :stream_halted})
        # Unlink first: the coordinator is linked to this (consuming) process,
        # and killing a live linked coordinator would otherwise take the
        # consumer down with it.
        Process.unlink(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.exit(pid, :kill)
        end

      _ ->
        :ok
    end

    :ok
  end

  defp cleanup(_owner, %{pid: pid, ref: ref} = state) when is_pid(pid) do
    demonitor_halt_ref(state)

    case Process.alive?(pid) do
      true ->
        send(pid, {:react_cancel, ref, :stream_halted})
        Process.unlink(pid)
        Process.exit(pid, :shutdown)

      _ ->
        :ok
    end

    :ok
  end

  defp monitor_halt_pid(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_halt_pid(_), do: nil

  defp demonitor_halt_ref(%{halt_ref: halt_ref}) when is_reference(halt_ref) do
    Process.demonitor(halt_ref, [:flush])
  end

  defp demonitor_halt_ref(_state), do: :ok

  defp start_task(fun, opts) do
    case Keyword.get(opts, :task_supervisor) do
      task_sup when is_pid(task_sup) ->
        Task.Supervisor.start_child(task_sup, fun)

      task_sup when is_atom(task_sup) and not is_nil(task_sup) ->
        case Process.whereis(task_sup) do
          pid when is_pid(pid) ->
            Task.Supervisor.start_child(task_sup, fun)

          _ ->
            Task.start(fun)
        end

      _ ->
        Task.start(fun)
    end
  end

  defp request_id_opts(opts) do
    opts
    |> Keyword.take([:request_id, :run_id])
  end

  defp latest_query(%State{} = state) do
    case Thread.last_entry(state.thread) do
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp append_query(%State{} = state, query) when is_binary(query) do
    %{
      state
      | thread: Thread.append_user(state.thread, query),
        status: :running,
        updated_at_ms: now_ms()
    }
  end

  @doc false
  # Append each non-blank steer text to the thread as a user message, in order.
  def apply_steer_texts(%State{} = state, texts) when is_list(texts) do
    thread =
      Enum.reduce(texts, state.thread, fn
        text, acc when is_binary(text) and text != "" -> Thread.append_user(acc, text)
        _, acc -> acc
      end)

    %{state | thread: thread}
  end

  def apply_steer_texts(%State{} = state, _), do: state

  defp drain_steering!(%State{} = state, ref) do
    receive do
      {:react_steer, ^ref, payload} ->
        texts = fetch_extra(payload, :texts, []) |> List.wrap()

        state
        |> apply_steer_texts(texts)
        |> drain_steering!(ref)
    after
      0 -> state
    end
  end

  defp to_reqllm_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &to_reqllm_tool_call/1)
  end

  defp to_reqllm_tool_calls(_), do: nil

  defp to_reqllm_tool_call(%ReqLLM.ToolCall{} = tc), do: tc

  defp to_reqllm_tool_call(%{} = call) do
    id = fetch_field(call, :id)
    name = fetch_field(call, :name)
    arguments = fetch_field(call, :arguments)

    args_json =
      case arguments do
        a when is_binary(a) -> a
        a when is_map(a) -> Jason.encode!(a)
        _ -> "{}"
      end

    ReqLLM.ToolCall.new(id, name, args_json)
  end

  defp maybe_thinking_opt(nil), do: []
  defp maybe_thinking_opt(""), do: []
  defp maybe_thinking_opt(thinking), do: [thinking: thinking]

  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value

  defp maybe_put_initial_messages_in_context(context, msgs)
       when is_list(msgs) and msgs != [],
       do: Map.put(context, :initial_messages, msgs)

  defp maybe_put_initial_messages_in_context(context, _), do: context

  defp maybe_redact_args(arguments, %Config{} = config) do
    case config.observability[:redact_tool_args?] do
      true -> Jido.AI.Observe.sanitize_sensitive(arguments)
      _ -> arguments
    end
  end

  defp check_cancel!(%State{} = state, ref) do
    receive do
      {:react_cancel, ^ref, reason} -> throw({:cancelled, state, reason})
    after
      0 -> :ok
    end
  end

  defp fetch_extra(extra, key, default \\ nil)

  defp fetch_extra(extra, key, default) when is_map(extra) do
    Map.get(extra, key, default)
  end

  defp fetch_extra(extra, key, default) when is_list(extra) do
    Keyword.get(extra, key, default)
  end

  defp request_stream_cancel(%{cancel_sent?: true} = state, _reason), do: state

  defp request_stream_cancel(%{pid: pid, ref: ref} = state, reason) when is_pid(pid) do
    case Process.alive?(pid) do
      true -> send(pid, {:react_cancel, ref, reason})
      _ -> :ok
    end

    Map.put(state, :cancel_sent?, true)
  end

  defp request_stream_cancel(state, _reason), do: state

  defp request_stream_steer(%{pid: pid, ref: ref} = state, payload) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, {:react_steer, ref, payload})
    state
  end

  defp request_stream_steer(state, _payload), do: state

  # Runs the tool in a task so a hung tool can be cut off at the configured
  # timeout instead of blocking the turn forever. Exceptions are converted
  # inside the task, so the link to this process never fires abnormally and
  # existing error result shapes are preserved.
  defp safe_execute_module(module, params, context, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    task =
      Task.async(fn ->
        try do
          module.run(params, context)
        rescue
          error ->
            {:error,
             %{
               type: :exception,
               error: Exception.message(error),
               exception_type: error.__struct__
             }}
        catch
          kind, reason ->
            {:error, %{type: :caught, kind: kind, error: inspect(reason)}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, %{type: :execution_error, error: inspect(reason)}}

      nil ->
        {:error,
         %{
           type: :timeout,
           error: "Tool execution exceeded #{timeout}ms and was aborted",
           timeout_ms: timeout
         }}
    end
  end

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_), do: 15_000

  defp normalize_retry_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_retry_count(_), do: 0

  defp normalize_backoff(value) when is_integer(value) and value >= 0, do: value
  defp normalize_backoff(_), do: 0

  defp tool_context_for(context, _tool_name) when not is_map(context), do: %{}

  defp tool_context_for(context, tool_name) when is_binary(tool_name) do
    base_context =
      context
      |> Map.delete(:__tool_contexts__)
      |> Map.delete("__tool_contexts__")

    per_tool_contexts =
      Map.get(context, :__tool_contexts__) || Map.get(context, "__tool_contexts__") || %{}

    per_tool_context =
      Map.get(per_tool_contexts, tool_name) ||
        maybe_get_atom_tool_context(per_tool_contexts, tool_name) ||
        %{}

    if is_map(per_tool_context) do
      Map.merge(base_context, per_tool_context)
    else
      base_context
    end
  end

  defp maybe_get_atom_tool_context(contexts, tool_name)
       when is_binary(tool_name) and is_map(contexts) do
    case String.to_existing_atom(tool_name) do
      atom_key -> Map.get(contexts, atom_key)
    end
  rescue
    ArgumentError -> nil
  end

  defp decode_html_entities(args) when is_map(args) do
    Map.new(args, fn {key, value} ->
      {key, decode_html_entities(value)}
    end)
  end

  defp decode_html_entities(args) when is_list(args) do
    Enum.map(args, &decode_html_entities/1)
  end

  defp decode_html_entities(value) when is_binary(value) do
    Enum.reduce(@html_entities, value, fn {entity, replacement}, acc ->
      String.replace(acc, entity, replacement)
    end)
  end

  defp decode_html_entities(value), do: value

  defp now_ms, do: System.system_time(:millisecond)
end
