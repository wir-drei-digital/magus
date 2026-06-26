defmodule Magus.Agents.Plugins.ActivityLogPlugin do
  @moduledoc """
  Unified activity logging plugin.

  Intercepts signals flowing through the Jido plugin pipeline and creates
  `AgentActivityLog` entries automatically. Replaces explicit logging calls
  scattered across other plugins.

  Must be the LAST plugin in the pipeline to observe all preceding signal processing.
  """

  use Jido.Plugin,
    name: "activity_log",
    state_key: :activity_log,
    actions: [],
    description: "Unified activity logging for agent signals",
    category: "magus",
    tags: ["logging", "activity"],
    signal_patterns: [
      "ai.request.*",
      "ai.tool.result",
      "ai.usage"
    ]

  require Logger

  alias Magus.Agents.Tools.Catalog
  alias Magus.Agents.Tools.Search.ActorContext

  @mutating_memory_tools ~w(create_memory set_memory clear_memory)

  # Per-request token/model accumulator (process dict key). The agent process is
  # per-conversation, so this is request-scoped; it is consumed + cleared on the
  # terminal ai.request.completed / ai.request.failed signal.
  @usage_acc_key :activity_log_usage_acc

  # ── ai.usage ──────────────────────────────────────────────────────────
  # Not logged on its own — accumulates the request's model + token totals so
  # the terminal :response_sent log can report them.

  def handle_signal(%{type: "ai.usage"} = signal, _context) do
    accumulate_usage(signal.data || %{})
    {:ok, :continue}
  end

  # ── ai.request.completed ──────────────────────────────────────────────

  def handle_signal(%{type: "ai.request.completed"} = signal, context) do
    agent = context[:agent]
    result = signal_result(signal)
    empty? = blank_text?(result)
    usage = take_usage_acc()

    maybe_log(agent, fn agent_id, _user ->
      %{
        agent_id: agent_id,
        activity_type: :response_sent,
        summary: "Response completed",
        conversation_id: get_conversation_id(agent),
        model_used: usage.model || conversation_model(agent),
        tokens_used: positive_or_nil(usage.tokens),
        details: %{
          conversation_id: get_conversation_id(agent),
          finish_reason: if(empty?, do: "empty", else: "stop"),
          empty?: empty?
        }
      }
    end)

    # Check if IntegrationReplyPlugin dispatched a reply
    case Process.get(:activity_log_integration_reply) do
      nil ->
        :ok

      %{provider: provider, conversation_id: conv_id} ->
        Process.delete(:activity_log_integration_reply)

        maybe_log(agent, fn agent_id, _user ->
          %{
            agent_id: agent_id,
            activity_type: :response_sent,
            summary: "Integration reply sent via #{provider}",
            conversation_id: conv_id,
            details: %{conversation_id: conv_id, provider: provider}
          }
        end)
    end

    # Check if AgentRunCompletionPlugin left a completed run
    case Process.get(:activity_log_last_completed_run) do
      nil ->
        :ok

      run ->
        Process.delete(:activity_log_last_completed_run)

        maybe_log(agent, fn agent_id, _user ->
          %{
            agent_id: agent_id,
            activity_type: :run_completed,
            summary: "Run completed: #{truncate(run.objective, 200)}",
            run_id: run.id,
            event_id: run.event_id,
            task_id: run.task_id,
            conversation_id: get_conversation_id(agent),
            duration_ms: run.duration_ms,
            model_used: Map.get(run, :model_key),
            details: %{
              conversation_id: get_conversation_id(agent),
              objective: run.objective,
              run_id: run.id,
              finish_reason: run_finish_reason(Map.get(run, :status)),
              empty?: blank_text?(Map.get(run, :result_text))
            }
          }
        end)
    end

    {:ok, :continue}
  end

  # ── ai.request.failed ─────────────────────────────────────────────────

  def handle_signal(%{type: "ai.request.failed"} = signal, context) do
    agent = context[:agent]
    error_msg = extract_error(signal)
    # Consume (and clear) any usage accumulated before the failure.
    usage = take_usage_acc()

    maybe_log(agent, fn agent_id, _user ->
      %{
        agent_id: agent_id,
        activity_type: :error,
        summary: "Error: #{truncate(error_msg, 200)}",
        conversation_id: get_conversation_id(agent),
        model_used: usage.model || conversation_model(agent),
        tokens_used: positive_or_nil(usage.tokens),
        details: %{
          conversation_id: get_conversation_id(agent),
          error: error_msg,
          finish_reason: "error"
        }
      }
    end)

    # Check if AgentRunCompletionPlugin left a failed run
    case Process.get(:activity_log_last_failed_run) do
      nil ->
        :ok

      run ->
        Process.delete(:activity_log_last_failed_run)

        maybe_log(agent, fn agent_id, _user ->
          %{
            agent_id: agent_id,
            activity_type: :run_failed,
            summary: "Run failed: #{truncate(run.objective, 200)}",
            run_id: run.id,
            event_id: run.event_id,
            task_id: run.task_id,
            conversation_id: get_conversation_id(agent),
            duration_ms: run.duration_ms,
            model_used: Map.get(run, :model_key),
            details: %{
              conversation_id: get_conversation_id(agent),
              objective: run.objective,
              run_id: run.id,
              error: error_msg,
              finish_reason: run_finish_reason(Map.get(run, :status)),
              empty?: blank_text?(Map.get(run, :result_text))
            }
          }
        end)
    end

    {:ok, :continue}
  end

  # ── ai.tool.result ────────────────────────────────────────────────────

  def handle_signal(%{type: "ai.tool.result"} = signal, context) do
    agent = context[:agent]
    data = signal.data || %{}
    tool_name = data[:tool_name] || data["tool_name"]

    cond do
      tool_name == "spawn_sub_agent" ->
        objective =
          get_in(data, [:params, "objective"]) ||
            get_in(data, ["params", "objective"]) || "Sub-agent task"

        run_id = get_in(data, [:result, :run_id]) || get_in(data, [:result, "run_id"])

        maybe_log(agent, fn agent_id, _user ->
          %{
            agent_id: agent_id,
            activity_type: :run_spawned,
            summary: "Sub-agent spawned: #{truncate(objective, 200)}",
            conversation_id: get_conversation_id(agent),
            run_id: run_id,
            details: %{
              conversation_id: get_conversation_id(agent),
              objective: objective,
              run_id: run_id
            }
          }
        end)

      tool_name in @mutating_memory_tools ->
        maybe_log(agent, fn agent_id, _user ->
          %{
            agent_id: agent_id,
            activity_type: :memory_updated,
            summary: "Memory #{tool_name}",
            conversation_id: get_conversation_id(agent),
            details: %{
              conversation_id: get_conversation_id(agent),
              tool: tool_name
            }
          }
        end)

      true ->
        # Cheap pre-guard: every coined MCP tool name has the shape
        # `<handle>__<slug>` (guaranteed by `ToolAdapter.coin_tool_name/2`,
        # which always joins with `"__"`). A name with no `"__"` can NEVER
        # be an MCP tool, so we skip the DB work entirely for the common case
        # (internal tools like `web_search`, `read_brain`, etc.).
        # The authoritative detection still comes from `Catalog.resolve/2`
        # for names that DO contain `__`.
        case String.contains?(tool_name || "", "__") && mcp_tool_info(agent, tool_name) do
          x when x in [nil, false] ->
            :ok

          %{handle: handle, remote_name: remote_name} ->
            outcome = tool_outcome(data[:result] || data["result"])

            maybe_log(agent, fn agent_id, _user ->
              %{
                agent_id: agent_id,
                activity_type: :external_tool_call,
                summary: "MCP #{handle}: #{remote_name} (#{outcome})",
                conversation_id: get_conversation_id(agent),
                details: %{
                  conversation_id: get_conversation_id(agent),
                  tool: tool_name,
                  mcp_server_handle: handle,
                  remote_name: remote_name,
                  outcome: outcome
                }
              }
            end)
        end
    end

    {:ok, :continue}
  end

  # ── Catch-all ──────────────────────────────────────────────────────────

  def handle_signal(_signal, _context), do: {:ok, :continue}

  # ── Private helpers ────────────────────────────────────────────────────

  defp maybe_log(agent, build_attrs_fn) do
    state = agent.state || %{}
    user_id = state[:user_id]

    with user_id when is_binary(user_id) <- user_id,
         user when not is_nil(user) <- cached_user(user_id),
         agent_id when not is_nil(agent_id) <- resolve_agent_id(state, user) do
      attrs = build_attrs_fn.(agent_id, user)
      do_create_log(attrs, user)
    end
  rescue
    e ->
      Logger.warning("ActivityLogPlugin: failed to create log: #{Exception.message(e)}")
  end

  defp do_create_log(attrs, user) do
    if Application.get_env(:magus, :activity_log_async, true) do
      Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
        create_log(attrs, user)
      end)
    else
      create_log(attrs, user)
    end
  end

  defp create_log(attrs, user) do
    case Magus.Agents.create_activity_log(attrs, actor: user, authorize?: false) do
      {:ok, _log} -> :ok
      {:error, err} -> Logger.warning("ActivityLogPlugin: log creation failed: #{inspect(err)}")
    end
  rescue
    e -> Logger.warning("ActivityLogPlugin: log creation error: #{Exception.message(e)}")
  end

  defp resolve_agent_id(state, user) do
    state[:custom_agent_id] ||
      resolve_agent_from_conversation(state[:conversation_id]) ||
      cached_default_agent_id(user)
  end

  defp resolve_agent_from_conversation(nil), do: nil

  defp resolve_agent_from_conversation(conversation_id) do
    case Process.get(:activity_log_conversation_agent_id) do
      nil ->
        case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
          {:ok, conv} ->
            agent_id = conv.custom_agent_id
            if agent_id, do: Process.put(:activity_log_conversation_agent_id, agent_id)
            agent_id

          _ ->
            nil
        end

      cached ->
        cached
    end
  end

  defp cached_default_agent_id(user) do
    case Process.get(:activity_log_default_agent_id) do
      nil ->
        case Magus.Agents.get_default_agent(actor: user) do
          {:ok, agent} ->
            Process.put(:activity_log_default_agent_id, agent.id)
            agent.id

          _ ->
            nil
        end

      cached ->
        cached
    end
  end

  defp cached_user(user_id) do
    case Process.get(:activity_log_user) do
      nil ->
        case Magus.Accounts.get_user(user_id, authorize?: false) do
          {:ok, user} ->
            Process.put(:activity_log_user, user)
            user

          _ ->
            nil
        end

      cached ->
        cached
    end
  end

  defp get_conversation_id(agent) do
    state = agent.state || %{}
    state[:conversation_id]
  end

  # ── MCP tool detection ──────────────────────────────────────────────────
  #
  # Reverse-resolve a coined tool name through the actor-scoped Catalog (the
  # single MCP access checkpoint, a pure cache read of the actor's accessible
  # servers). Returns `%{server_id, remote_name, handle}` when `tool_name` is an
  # MCP tool loaded into this conversation, or `nil` otherwise. Degrades to nil
  # (no log) for a non-MCP tool, a missing conversation, or a missing actor.
  defp mcp_tool_info(agent, tool_name) when is_binary(tool_name) do
    state = agent.state || %{}

    with conversation_id when is_binary(conversation_id) <- state[:conversation_id],
         actor_context = ActorContext.from(state),
         %{user: user} when not is_nil(user) <- actor_context,
         {:ok, conversation} <-
           Magus.Chat.get_conversation(conversation_id, actor: user) do
      loaded_tools = conversation.loaded_tools || []
      {_modules, mcp_tools, _unknown} = Catalog.resolve(loaded_tools, actor_context)

      case Enum.find(mcp_tools, &(&1.coined_name == tool_name)) do
        nil ->
          nil

        %{server_id: server_id, remote_name: remote_name} ->
          %{
            server_id: server_id,
            remote_name: remote_name,
            handle: server_handle(server_id, user)
          }
      end
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("ActivityLogPlugin: MCP detection failed: #{Exception.message(e)}")
      nil
  end

  defp mcp_tool_info(_agent, _tool_name), do: nil

  # The carrier exposes server_id + remote_name; recover the human-readable
  # handle from the actor-scoped server record (falling back to the id).
  defp server_handle(server_id, user) do
    case Magus.MCP.get_server(server_id, actor: user) do
      {:ok, %{handle: handle}} when is_binary(handle) -> handle
      _ -> server_id
    end
  end

  # The MCP Executor always returns {:ok, map}; a soft error is a map carrying
  # an :error / "error" key. Anything else is a success.
  defp tool_outcome({:ok, result}), do: tool_outcome(result)
  defp tool_outcome({:error, _}), do: "error"

  defp tool_outcome(%{error: _}), do: "error"
  defp tool_outcome(%{"error" => _}), do: "error"
  defp tool_outcome(_), do: "ok"

  # ── token/model enrichment helpers ──────────────────────────────────────

  defp accumulate_usage(data) do
    model = data[:model] || data["model"]
    input = to_int(data[:input_tokens] || data["input_tokens"])
    output = to_int(data[:output_tokens] || data["output_tokens"])

    acc = Process.get(@usage_acc_key, %{model: nil, tokens: 0})

    Process.put(@usage_acc_key, %{
      model: blank_to_nil(model) || acc.model,
      tokens: acc.tokens + input + output
    })
  end

  defp take_usage_acc do
    acc = Process.get(@usage_acc_key, %{model: nil, tokens: 0})
    Process.delete(@usage_acc_key)
    acc
  end

  defp conversation_model(agent) do
    case (agent.state || %{})[:model_keys] do
      %{chat: chat} -> blank_to_nil(chat)
      _ -> nil
    end
  end

  defp signal_result(%{data: data}) when is_map(data), do: data[:result] || data["result"]
  defp signal_result(_), do: nil

  defp run_finish_reason(:complete), do: "stop"

  defp run_finish_reason(status) when is_atom(status) and not is_nil(status),
    do: to_string(status)

  defp run_finish_reason(_), do: "unknown"

  defp blank_text?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank_text?(_), do: true

  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0

  defp positive_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_or_nil(_), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  defp extract_error(%{data: %{error: error}}) when is_binary(error), do: error
  defp extract_error(%{data: %{"error" => error}}) when is_binary(error), do: error
  defp extract_error(%{data: %{error: error}}), do: inspect(error)
  defp extract_error(%{data: %{"error" => error}}), do: inspect(error)
  defp extract_error(_), do: "Unknown error"

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(other, _max), do: inspect(other)
end
