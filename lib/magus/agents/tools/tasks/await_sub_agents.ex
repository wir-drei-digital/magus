defmodule Magus.Agents.Tools.Tasks.AwaitSubAgents do
  @moduledoc """
  Block the parent's turn until N sub-agents reach a terminal state.

  Subscribes to the `agents:{conversation_id}` PubSub topic and waits in `receive`,
  re-checking the DB on each completion-related broadcast (`run.completed`,
  `run.failed`, `tool.step.complete`) plus a polling fallback so we never depend
  solely on PubSub.
  Marks every newly-terminal run as `delivered_to_parent_at` before returning,
  so the auto-wake (`SubAgentResumer`) does not redeliver the same results.

  The actual sub-agent outputs live on the parent's spawn_sub_agent tool
  messages — `tool_call_data.output` is mutated to the terminal payload by
  `AgentRunCompletionPlugin`. This tool's return value is a light summary.
  """

  use Jido.Action,
    name: "await_sub_agents",
    description: """
    Block the current turn until N spawned sub-agents have terminated.

    Use only when you must inspect sub-agent results before deciding the next
    step. Otherwise, the spawn_sub_agent tool's output is automatically
    upgraded to the terminal result when the child finishes — you do not need
    to await unless you want to block.

    Returns a light summary; the actual sub-agent outputs are attached to
    each spawn_sub_agent tool call's output in this conversation.
    """,
    schema: [
      task_ids: [
        type: {:or, [{:list, :string}, nil]},
        default: nil,
        doc:
          "Specific task IDs (returned by spawn_sub_agent). If nil, waits on all subtasks from this conversation."
      ],
      wait_for: [
        type: {:in, [:all, :first, :any]},
        default: :all,
        doc: ":all (default), :first, or :any (must specify min_completed_count)."
      ],
      min_completed_count: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Required when wait_for is :any. Number of completions to satisfy."
      ],
      timeout_seconds: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Maximum seconds before returning status: \"timeout\". Default 1800 (30 min)."
      ]
    ]

  require Ash.Query
  require Logger

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  alias Magus.Agents.{AgentRun, Signals}

  @default_timeout_seconds 1800
  @terminal_statuses [:complete, :error, :timed_out, :cancelled]
  # Polling fallback — completion signals on the modern path arrive as
  # `tool.step.complete`, but we also re-check the DB on this interval so we
  # never depend solely on PubSub.
  @poll_interval_ms 2_000

  def display_name, do: "Waiting for sub-agents..."

  def summarize_output(%{status: "completed", satisfied: %{completed: n}}),
    do: "#{n} sub-agent(s) completed"

  def summarize_output(%{status: "partial", satisfied: %{completed: n}}),
    do: "Returned with #{n} sub-agent(s) completed"

  def summarize_output(%{status: "timeout"}), do: "Timed out waiting for sub-agents"
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Done"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        wait_for = parse_wait_for(get_param(params, :wait_for))
        min_count = get_param(params, :min_completed_count)
        task_ids = get_param(params, :task_ids)
        timeout = parse_timeout(get_param(params, :timeout_seconds))

        case validate_wait_for(wait_for, min_count) do
          {:ok, satisfaction} ->
            do_run(ctx.conversation_id, task_ids, satisfaction, timeout, context)

          {:error, msg} ->
            {:ok, %{error: msg}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_run(conversation_id, task_ids, satisfaction, timeout_seconds, full_context) do
    topic = "agents:#{conversation_id}"
    Magus.Endpoint.subscribe(topic)

    deadline = System.monotonic_time(:millisecond) + timeout_seconds * 1000

    try do
      runs = fetch_runs(conversation_id, task_ids)
      emit_waiting(full_context, runs)
      result = loop(conversation_id, task_ids, satisfaction, deadline, runs, full_context)
      mark_delivered(result.terminal)
      build_response(result, runs)
    after
      Magus.Endpoint.unsubscribe(topic)
    end
  end

  defp loop(conversation_id, task_ids, satisfaction, deadline, runs, full_context) do
    {terminal, in_flight} = partition(runs)

    cond do
      satisfied?(satisfaction, terminal, in_flight) ->
        %{status: :completed, terminal: terminal, total: length(runs)}

      System.monotonic_time(:millisecond) >= deadline ->
        %{status: :timeout, terminal: terminal, total: length(runs)}

      true ->
        poll_at = System.monotonic_time(:millisecond) + @poll_interval_ms
        drain(conversation_id, task_ids, satisfaction, deadline, poll_at, runs, full_context)
    end
  end

  # Wait for a meaningful PubSub event or a poll-tick, whichever comes first.
  # `_other` events (text chunks, our own tool.progress echoes, sub-agent tool
  # events, etc.) are drained without resetting `poll_at` so the polling
  # fallback always fires within @poll_interval_ms.
  defp drain(conversation_id, task_ids, satisfaction, deadline, poll_at, runs, full_context) do
    ms_left = max(min(poll_at, deadline) - System.monotonic_time(:millisecond), 0)

    receive do
      %Phoenix.Socket.Broadcast{payload: %{type: type}}
      when type in ["run.completed", "run.failed", "tool.step.complete"] ->
        refetch_and_continue(
          conversation_id,
          task_ids,
          satisfaction,
          deadline,
          runs,
          full_context
        )

      _other ->
        drain(conversation_id, task_ids, satisfaction, deadline, poll_at, runs, full_context)
    after
      ms_left ->
        refetch_and_continue(
          conversation_id,
          task_ids,
          satisfaction,
          deadline,
          runs,
          full_context
        )
    end
  end

  defp refetch_and_continue(conversation_id, task_ids, satisfaction, deadline, runs, full_context) do
    new_runs = fetch_runs(conversation_id, task_ids)

    if terminal_count(new_runs) != terminal_count(runs) do
      emit_waiting(full_context, new_runs)
    end

    loop(conversation_id, task_ids, satisfaction, deadline, new_runs, full_context)
  end

  defp emit_waiting(full_context, runs) do
    {terminal, in_flight} = partition(runs)

    Signals.emit_tool_progress(full_context, :waiting, %{
      completed: length(terminal),
      pending: length(in_flight),
      total: length(runs)
    })
  end

  defp terminal_count(runs) do
    Enum.count(runs, fn run -> run.status in @terminal_statuses end)
  end

  # :all is satisfied when no runs are still in flight.
  # An empty run set means no work was found — immediately satisfied (no waiting required).
  defp satisfied?(:all, _terminal, in_flight), do: in_flight == []

  defp satisfied?(:first, terminal, _in_flight), do: length(terminal) >= 1

  defp satisfied?({:any, n}, terminal, _in_flight), do: length(terminal) >= n

  defp partition(runs) do
    Enum.split_with(runs, fn run -> run.status in @terminal_statuses end)
  end

  defp fetch_runs(conversation_id, task_ids) when is_list(task_ids) and task_ids != [] do
    case AgentRun
         |> Ash.Query.filter(id in ^task_ids and source_conversation_id == ^conversation_id)
         |> Ash.read(authorize?: false) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp fetch_runs(conversation_id, _task_ids) do
    case AgentRun
         |> Ash.Query.filter(source_conversation_id == ^conversation_id and kind == :subtask)
         |> Ash.read(authorize?: false) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp parse_wait_for(:all), do: :all
  defp parse_wait_for(:first), do: :first
  defp parse_wait_for(:any), do: :any
  defp parse_wait_for("all"), do: :all
  defp parse_wait_for("first"), do: :first
  defp parse_wait_for("any"), do: :any
  defp parse_wait_for(_), do: :all

  defp parse_timeout(nil), do: @default_timeout_seconds
  defp parse_timeout(n) when is_integer(n) and n > 0, do: n
  defp parse_timeout(s) when is_binary(s), do: String.to_integer(s)
  defp parse_timeout(_), do: @default_timeout_seconds

  defp validate_wait_for(:any, n) when is_integer(n) and n > 0, do: {:ok, {:any, n}}

  defp validate_wait_for(:any, _),
    do: {:error, "wait_for: :any requires min_completed_count > 0"}

  defp validate_wait_for(other, _), do: {:ok, other}

  defp mark_delivered(runs) do
    runs
    |> Enum.filter(&is_nil(&1.delivered_to_parent_at))
    |> Enum.each(fn run ->
      Magus.Agents.mark_delivered_agent_run(run, authorize?: false)
    end)
  rescue
    e ->
      Logger.warning("AwaitSubAgents.mark_delivered failed: #{Exception.message(e)}")
      :ok
  end

  defp build_response(%{status: status, terminal: terminal, total: total}, _all_runs) do
    summaries =
      Enum.map(terminal, fn run ->
        %{
          task_id: to_string(run.id),
          status: to_string(run.status),
          agent_name: get_in(run.metadata, ["agent_name"]),
          error: run.error_message
        }
      end)

    {:ok,
     %{
       status: response_status_for(status, terminal, total),
       satisfied: %{completed: length(terminal), total: total},
       task_summaries: summaries,
       note: "Detailed results are attached to each spawn_sub_agent tool call's output above."
     }}
  end

  defp response_status_for(:completed, _, _), do: "completed"
  defp response_status_for(:timeout, [], _), do: "timeout"
  defp response_status_for(:timeout, _, _), do: "partial"
end
