defmodule Magus.Agents.RunOrchestrator do
  @moduledoc """
  Stateless orchestrator for AgentRun execution.

  - Persists runs via AgentRun
  - Starts bounded active runs per target conversation
  - Emits `run.*` lifecycle events to the source conversation
  """

  import Ecto.Query

  require Ash.Query
  require Logger

  alias Magus.Agents.AgentRun
  alias Magus.Agents.Signals
  alias Magus.Agents.Support.AgentBootstrap
  alias Magus.Agents.Telemetry
  alias Magus.Repo

  @type enqueue_outcome :: :created | :existing
  @type enqueue_result ::
          {:ok, AgentRun.t()} | {:ok, enqueue_outcome(), AgentRun.t()} | {:error, term()}
  @default_max_parallel_runs_per_target 3
  @autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]
  @budget_gated_sources [:heartbeat, :inbox_urgent]

  @doc """
  Enqueue an `AgentRun`. Returns:

    * `{:ok, run}` for back-compat callers that don't care about idempotency.

  Use `enqueue_with_outcome/1` when you need to distinguish a newly created
  run from an idempotency-key replay (used by `HeartbeatScheduler` to avoid
  writing a duplicate "Heartbeat started" trace message on replay).
  """
  @spec enqueue(map()) :: {:ok, AgentRun.t()} | {:error, term()}
  def enqueue(attrs) when is_map(attrs) do
    case enqueue_with_outcome(attrs) do
      {:ok, _outcome, run} -> {:ok, run}
      {:error, _} = err -> err
    end
  end

  @spec enqueue_with_outcome(map()) ::
          {:ok, enqueue_outcome(), AgentRun.t()} | {:error, term()}
  def enqueue_with_outcome(attrs) when is_map(attrs) do
    with :ok <- check_no_in_flight_autonomous_run(attrs),
         :ok <- check_daily_run_budget(attrs),
         :ok <- check_owner_spend_budget(attrs),
         {:ok, outcome, run} <- find_or_create_run(attrs) do
      if outcome == :created, do: Telemetry.run_event(:enqueued, run)

      source_conversation_id = to_string(run.source_conversation_id)

      Signals.run_progress(source_conversation_id, %{
        run_id: to_string(run.id),
        status: "queued",
        kind: to_string(run.kind),
        objective: truncate(run.objective, 180),
        target_agent_id: run.target_agent_id,
        target_conversation_id: run.target_conversation_id,
        request_id: run.request_id,
        source_event_id: run.source_event_id
      })

      maybe_start_next(run.target_conversation_id)
      {:ok, outcome, run}
    end
  end

  # ---------------------------------------------------------------------------
  # Autonomous-run / heartbeat enqueue gates
  # ---------------------------------------------------------------------------
  #
  # `check_no_in_flight_autonomous_run/1` covers `:heartbeat`, `:manual_trigger`,
  # and `:inbox_urgent` so a double-clicked "Run now" button, a scheduled
  # heartbeat, and an urgent inbox-event wakeup can't fire concurrent
  # autonomous runs for the same agent.
  #
  # The remaining two gates (`check_daily_run_budget/1`,
  # `check_owner_spend_budget/1`) apply to `:heartbeat` and `:inbox_urgent`
  # since those are the owner-cost / quota gates for unattended wakeups.
  # `:manual_trigger` is user-initiated and keeps its exemption from the
  # budget gates. `:mention` and `:sub_agent_spawn` runs are user- or
  # parent-driven and rely on the existing `max_parallel_runs_per_target`
  # bound for backpressure.

  defp check_no_in_flight_autonomous_run(%{source: source, target_agent_id: agent_id})
       when source in @autonomous_sources and not is_nil(agent_id) do
    in_flight =
      AgentRun
      |> Ash.Query.filter(
        target_agent_id == ^agent_id and
          source in ^@autonomous_sources and
          status in [:pending, :running]
      )
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case in_flight do
      [] -> :ok
      [_ | _] -> {:error, :already_running}
    end
  end

  defp check_no_in_flight_autonomous_run(_), do: :ok

  defp check_daily_run_budget(%{source: source, target_agent_id: agent_id})
       when source in @budget_gated_sources and not is_nil(agent_id) do
    case Ash.get(Magus.Agents.CustomAgent, agent_id, authorize?: false) do
      {:ok, agent} -> evaluate_daily_run_budget(agent, agent_id)
      {:error, _} -> :ok
    end
  end

  defp check_daily_run_budget(_), do: :ok

  defp evaluate_daily_run_budget(%{max_daily_runs: cap}, _agent_id)
       when is_nil(cap) or cap == 0,
       do: :ok

  defp evaluate_daily_run_budget(%{max_daily_runs: cap}, agent_id) when is_integer(cap) do
    window_start = DateTime.add(DateTime.utc_now(), -86_400, :second)

    runs =
      AgentRun
      |> Ash.Query.filter(
        target_agent_id == ^agent_id and
          source in ^@budget_gated_sources and
          inserted_at >= ^window_start and
          status != :cancelled
      )
      |> Ash.read!(authorize?: false)

    if length(runs) >= cap, do: {:error, :budget_exceeded}, else: :ok
  end

  defp evaluate_daily_run_budget(_agent, _agent_id), do: :ok

  defp check_owner_spend_budget(%{source: source, initiator_user_id: user_id})
       when source in @budget_gated_sources and not is_nil(user_id) do
    case Magus.Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} ->
        case Magus.Usage.PolicyEnforcer.check_spend_budget(user) do
          {:ok, :allowed} ->
            :ok

          {:error, %{limit_type: t}} when t in [:spend_cap, :trial_cap, :payment_required] ->
            {:error, :insufficient_spend_budget}

          # Any other PolicyError variant (or unexpected shape) is treated as
          # not blocking heartbeat enqueue here: the only signal we care about
          # at this gate is "this user is out of pay-per-use budget".
          _other ->
            :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp check_owner_spend_budget(_), do: :ok

  @spec maybe_start_next(Ecto.UUID.t() | String.t() | nil) :: :ok
  def maybe_start_next(nil), do: :ok

  def maybe_start_next(target_conversation_id) do
    target_conversation_id = to_string(target_conversation_id)
    max_parallel = max_parallel_runs_per_target()

    case claim_pending_runs(target_conversation_id, max_parallel) do
      {:ok, []} ->
        :ok

      {:ok, runs} ->
        Enum.each(runs, &start_claimed_run/1)
        :ok

      {:error, reason} ->
        Logger.warning(
          "RunOrchestrator: failed to claim runs for target #{target_conversation_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp start_claimed_run(run) do
    boot_opts = if run.model_key, do: [model_key: run.model_key], else: []

    with {:ok, boot} <-
           AgentBootstrap.ensure_conversation_agent(run.target_conversation_id, boot_opts),
         :ok <- dispatch_to_target(boot.pid, run) do
      Telemetry.run_event(:started, run)
      Signals.run_started(to_string(run.source_conversation_id), run_payload(run))
      :ok
    else
      {:error, {:registry_unavailable, _reason}} ->
        # Tests and some boot scenarios run without InstanceManager.
        # Re-queue the run so it can be retried later.
        requeue_run(run)
        :ok

      {:error, reason} ->
        Logger.warning("RunOrchestrator: failed to start run #{run.id}: #{inspect(reason)}")
        fail_run(run, reason)
        maybe_start_next(run.target_conversation_id)
        :ok
    end
  end

  defp requeue_run(run) do
    case Magus.Agents.requeue_agent_run(run, authorize?: false) do
      {:ok, _requeued} ->
        :ok

      {:error, reason} ->
        Logger.warning("RunOrchestrator: failed to requeue run #{run.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp fail_run(run, reason) do
    formatted = format_error(reason)

    case Magus.Agents.fail_agent_run(run, %{error_message: formatted}, authorize?: false) do
      {:ok, failed_run} ->
        Signals.run_failed(to_string(failed_run.source_conversation_id), %{
          run_id: to_string(failed_run.id),
          status: "error",
          kind: to_string(failed_run.kind),
          objective: truncate(failed_run.objective, 180),
          target_agent_id: failed_run.target_agent_id,
          target_conversation_id: failed_run.target_conversation_id,
          request_id: failed_run.request_id,
          error: formatted
        })

        run_fail_side_effects(failed_run)

      {:error, fail_reason} ->
        Logger.warning(
          "RunOrchestrator: failed to mark run #{run.id} as failed: #{inspect(fail_reason)}"
        )
    end
  end

  @autonomous_fail_sources [:heartbeat, :manual_trigger, :inbox_urgent]

  @doc false
  # Reliability machinery for a run that failed to claim/boot/dispatch. The
  # AgentRunCompletionPlugin runs these same effects when a run fails *during*
  # execution (an `ai.request.failed` signal), but a start-time failure never
  # reaches that plugin, so we mirror them here:
  #
  #   1. `run.failed` telemetry — observability parity with in-flight failures.
  #   2. Unlink linked inbox events — clears `agent_run_id` so the next
  #      heartbeat reconsiders the event instead of it staying stuck.
  #   3. FailureStreak escalation for autonomous sources — a start-time failure
  #      still counts toward the auto-pause streak.
  #
  # Each effect is defensive: FailureStreak/unlink never raise, and telemetry
  # is best-effort.
  def run_fail_side_effects(failed_run) do
    Telemetry.run_event(:failed, failed_run)
    Magus.Agents.AgentRunHelpers.unlink_linked_inbox_events(failed_run)
    maybe_check_failure_streak(failed_run)
    :ok
  end

  defp maybe_check_failure_streak(%{source: source, target_agent_id: agent_id})
       when source in @autonomous_fail_sources and is_binary(agent_id) do
    Magus.Agents.Support.FailureStreak.check_and_escalate(agent_id)
    :ok
  end

  defp maybe_check_failure_streak(_run), do: :ok

  defp dispatch_to_target(pid, run) do
    signal = Jido.Signal.new!("message.user", build_run_signal_payload(run))

    with :ok <- Jido.AgentServer.attach(pid),
         :ok <- Jido.AgentServer.cast(pid, signal) do
      :ok
    end
  end

  @doc false
  # Build the `message.user` signal payload for an AgentRun dispatch.
  #
  # `acting_user_id` is set to `run.initiator_user_id` (the agent's owning user
  # for heartbeat/manual runs). It flows into `data[:acting_user_id]` in
  # `Preflight.build_request_context`, which the MCP actor uses (Phase 3 Tasks
  # 1-2). When `initiator_user_id` is nil, the key is left nil so the run-path
  # `build_request_context` falls back to `state[:user_id]` (= the conversation
  # owner) — never a bare `ai_actor()`.
  #
  # Pure map computation (no DB access) so it is unit-testable; see
  # `test/magus/mcp/phase3_acting_user_test.exs`.
  def build_run_signal_payload(run) do
    payload = %{
      text: run.objective,
      message_id: run.request_id,
      attachments: [],
      mode: :chat,
      acting_user_id: run.initiator_user_id,
      run_id: to_string(run.id),
      run_kind: run.kind,
      run_source: run.source && to_string(run.source),
      source_conversation_id: to_string(run.source_conversation_id),
      source_message_id: run.source_message_id && to_string(run.source_message_id),
      target_agent_id: run.target_agent_id,
      target_conversation_id: run.target_conversation_id
    }

    # Pass model_key from AgentRun so Preflight uses it over stale agent state
    if is_binary(run.model_key) do
      Map.put(payload, :model_keys, %{chat: run.model_key})
    else
      payload
    end
  end

  defp find_or_create_run(%{idempotency_key: key} = attrs) when is_binary(key) and key != "" do
    case AgentRun
         |> Ash.Query.filter(idempotency_key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, %AgentRun{} = run} ->
        {:ok, :existing, run}

      {:ok, nil} ->
        case Magus.Agents.create_agent_run(attrs, authorize?: false) do
          {:ok, run} ->
            {:ok, :created, run}

          {:error, reason} ->
            # Handle concurrent insert race on unique idempotency key.
            case AgentRun
                 |> Ash.Query.filter(idempotency_key == ^key)
                 |> Ash.read_one(authorize?: false) do
              {:ok, %AgentRun{} = run} -> {:ok, :existing, run}
              _ -> {:error, reason}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_or_create_run(attrs) do
    case Magus.Agents.create_agent_run(attrs, authorize?: false) do
      {:ok, run} -> {:ok, :created, run}
      {:error, _} = err -> err
    end
  end

  defp run_payload(run) do
    %{
      run_id: to_string(run.id),
      status: to_string(run.status),
      kind: to_string(run.kind),
      objective: truncate(run.objective, 180),
      target_agent_id: run.target_agent_id,
      target_conversation_id: run.target_conversation_id,
      request_id: run.request_id,
      source_event_id: run.source_event_id
    }
  end

  defp max_parallel_runs_per_target do
    :magus
    |> Application.get_env(:agents, [])
    |> Keyword.get(:max_parallel_runs_per_target, @default_max_parallel_runs_per_target)
    |> case do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_parallel_runs_per_target
    end
  end

  defp claim_pending_runs(_target_conversation_id, max_parallel) when max_parallel <= 0,
    do: {:ok, []}

  defp claim_pending_runs(target_conversation_id, max_parallel) do
    case Repo.transaction(fn -> do_claim_pending_runs(target_conversation_id, max_parallel) end) do
      {:ok, runs} -> {:ok, runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_claim_pending_runs(target_conversation_id, max_parallel) do
    with :ok <- lock_target_queue(target_conversation_id),
         running_count <- running_count_for_target(target_conversation_id) do
      available_slots = max(max_parallel - running_count, 0)

      if available_slots == 0 do
        []
      else
        pending_ids = next_pending_ids(target_conversation_id, available_slots)

        if pending_ids == [] do
          []
        else
          now = DateTime.utc_now()

          _ =
            from(r in AgentRun,
              where: r.id in ^pending_ids and r.status == :pending
            )
            |> Repo.update_all(
              set: [
                status: :running,
                started_at: now,
                last_heartbeat_at: now,
                updated_at: now
              ]
            )

          load_runs_in_id_order(pending_ids)
        end
      end
    end
  end

  defp lock_target_queue(target_conversation_id) do
    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtext($1), 0)",
           [target_conversation_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp running_count_for_target(target_conversation_id) do
    from(r in AgentRun,
      where: r.target_conversation_id == ^target_conversation_id and r.status == :running,
      select: count(r.id)
    )
    |> Repo.one()
  end

  defp next_pending_ids(target_conversation_id, limit) do
    from(r in AgentRun,
      where: r.target_conversation_id == ^target_conversation_id and r.status == :pending,
      order_by: [asc: r.inserted_at],
      limit: ^limit,
      lock: "FOR UPDATE SKIP LOCKED",
      select: r.id
    )
    |> Repo.all()
    |> Enum.map(&to_string/1)
  end

  defp load_runs_in_id_order([]), do: []

  defp load_runs_in_id_order(run_ids) do
    case AgentRun
         |> Ash.Query.filter(id in ^run_ids)
         |> Ash.read(authorize?: false) do
      {:ok, runs} ->
        runs_by_id = Map.new(runs, fn run -> {to_string(run.id), run} end)

        run_ids
        |> Enum.map(&Map.get(runs_by_id, &1))
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)

  defp truncate(text, _max) when not is_binary(text), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "...", else: text
  end
end
