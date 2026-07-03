# Event-Driven Autonomy Phase 2: Run Liveness + Recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Long-running autonomous runs stop being falsely reaped (nothing pings `last_heartbeat_at` today), stuck `:pending` runs get swept, and turn recovery can no longer double-dispatch.

**Architecture:** A throttled `RunLiveness.touch/1` is called from the streaming/tool plugins (proof the agent is working); `CleanupStale` only reaps when the target process is actually gone or a hard duration cap is exceeded; a new ash_oban trigger sweeps stuck `:pending` runs; `Recovery` gains a newer-message guard and abort-on-not-ready. Spec: `docs/superpowers/specs/2026-07-03-event-driven-agent-autonomy-design.md` §4–§5.

**Tech Stack:** Elixir/Phoenix, Ash 3.x + AshPostgres + ash_oban, Jido plugins, ETS, ExUnit + `Magus.Generators`.

## Global Constraints

- Never run `mix ash.reset`. Schema changes via `mix ash.codegen <name>` + `mix ash.migrate`; also migrate the test partition: `MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix ash.migrate` (with `.env` sourced).
- All test commands: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test <path>`.
- Liveness throttle: at most one DB write per conversation per 30 seconds (`@touch_interval_ms 30_000`).
- Stale reap hard cap: 30 minutes (`max_run_duration_minutes`, read from `Application.get_env(:magus, :agents, [])`, default 30).
- Pending sweep: nudge after 15 minutes pending, `:timed_out` after 6 hours pending.
- `RunLiveness.touch/1` and every sweep/recovery path must never raise into its caller (rescue + log, mirroring existing plugin conventions).
- ash_oban triggers follow the existing `:cleanup_stale_runs` pattern in `lib/magus/agents/agent_run.ex:24-38` (worker/scheduler module names, `max_attempts 1`, `where expr(...)`, `read_action`).
- Commit per task with explicit paths after `--`.

---

### Task 1: `Magus.Agents.RunLiveness`

**Files:**
- Create: `lib/magus/agents/run_liveness.ex`
- Modify: `lib/magus/application.ex` (add child near the agents infrastructure children)
- Test: `test/magus/agents/run_liveness_test.exs` (new)

**Interfaces:**
- Produces: `RunLiveness.touch(conversation_id :: String.t() | Ecto.UUID.t() | nil) :: :ok` — throttled update of `last_heartbeat_at` on all `:running` runs targeting that conversation. `touch(nil)` is a no-op. Task 2 calls this from plugins. Test seam: `RunLiveness.reset_throttle(conversation_id)` clears the ETS entry.

- [ ] **Step 1: Write the failing tests**

`test/magus/agents/run_liveness_test.exs` — `use Magus.DataCase, async: false`, `import Magus.Generators`. Seed a user/agent/home-conversation + a `:running` `:heartbeat` run exactly like `test/magus/agents/trigger_urgent_wake_test.exs`'s `seed_running_heartbeat_run/2` does (copy that helper). Tests:

1. "touch updates last_heartbeat_at of running runs": capture `run.last_heartbeat_at`, sleep 1100ms (timestamp resolution), `RunLiveness.touch(home.id)`, reload run, assert `DateTime.compare(reloaded.last_heartbeat_at, run.last_heartbeat_at) == :gt`.
2. "touch is throttled": touch once, reload (t1); `RunLiveness.touch(home.id)` again immediately, reload, assert unchanged (== t1).
3. "reset_throttle allows immediate re-touch": after test 2's second touch, `RunLiveness.reset_throttle(home.id)`, sleep 1100ms, touch, assert `:gt` vs t1.
4. "touch ignores non-running runs": complete the run, reset throttle, touch, assert `last_heartbeat_at` unchanged.
5. "touch with nil / unknown conversation is :ok": `assert :ok = RunLiveness.touch(nil)`; `assert :ok = RunLiveness.touch(Ash.UUID.generate())`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/run_liveness_test.exs`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement**

```elixir
defmodule Magus.Agents.RunLiveness do
  @moduledoc """
  Throttled execution-liveness pings for AgentRuns.

  `CleanupStale` reaps runs whose `last_heartbeat_at` is older than 2
  minutes, but nothing updated that timestamp during execution, so any run
  doing more than ~2 minutes of real work was falsely timed out. Streaming
  and tool plugins call `touch/1` on activity; at most one DB write per
  conversation per #{div(30_000, 1000)}s keeps the hot path cheap.

  The ETS table is owned by this GenServer but written by caller processes
  (`:public`); losing it on a crash only means one extra DB write.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Magus.Agents.AgentRun
  alias Magus.Repo

  @table :agent_run_liveness
  @touch_interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Throttled: updates last_heartbeat_at on :running runs targeting the conversation."
  @spec touch(String.t() | Ecto.UUID.t() | nil) :: :ok
  def touch(nil), do: :ok

  def touch(conversation_id) do
    conversation_id = to_string(conversation_id)
    now_ms = System.monotonic_time(:millisecond)

    if due?(conversation_id, now_ms) do
      :ets.insert(@table, {conversation_id, now_ms})

      now = DateTime.utc_now()

      {_count, _} =
        from(r in AgentRun,
          where: r.target_conversation_id == ^conversation_id and r.status == :running
        )
        |> Repo.update_all(set: [last_heartbeat_at: now, updated_at: now])
    end

    :ok
  rescue
    e ->
      Logger.warning("RunLiveness.touch failed for #{inspect(conversation_id)}: #{Exception.message(e)}")
      :ok
  end

  @doc "Test seam: clears the throttle entry so the next touch writes immediately."
  def reset_throttle(conversation_id) do
    :ets.delete(@table, to_string(conversation_id))
    :ok
  rescue
    _ -> :ok
  end

  defp due?(conversation_id, now_ms) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, last_ms}] -> now_ms - last_ms >= @touch_interval_ms
      [] -> true
    end
  rescue
    # Table missing (owner restarting): fail open, allow the write.
    _ -> true
  end
end
```

Note: `Repo.update_all` with a uuid-typed column compares fine with a string binary; RunOrchestrator does the same (`next_pending_ids`). If the query errors on type, cast with `type(^conversation_id, Ecto.UUID)`.

Add to `lib/magus/application.ex` children (read the file; place next to the other agents-infra children, BEFORE the InstanceManager entries so it's up before agents run): `Magus.Agents.RunLiveness`.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/run_liveness_test.exs`
Expected: PASS. Also `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): RunLiveness throttled execution pings" -- lib/magus/agents/run_liveness.ex lib/magus/application.ex test/magus/agents/run_liveness_test.exs
```

---

### Task 2: Touch points in streaming/tool plugins

**Files:**
- Modify: `lib/magus/agents/plugins/streaming_plugin.ex` (handle_signal dispatch, moduledoc)
- Modify: `lib/magus/agents/plugins/tool_event_plugin.ex` (handle_signal dispatch)
- Test: `test/magus/agents/run_liveness_touchpoints_test.exs` (new)

**Interfaces:**
- Consumes: `RunLiveness.touch/1` (Task 1).
- Produces: any `ai.llm.delta`, `ai.llm.turn.completed`, `ai.tool.started`, or `ai.tool.result` signal handled by these plugins touches liveness for the agent's conversation.

- [ ] **Step 1: Write the failing test**

Both plugins' `handle_signal/2` take `(signal, context)` where `context[:agent]` yields the conversation id via `Magus.Agents.Plugins.Support.Helpers.get_conversation_id/1`. Read one existing plugin test (grep `test/magus/agents/plugins/` for streaming/tool tests) to copy how a minimal `context`/agent struct and `Jido.Signal.new!` are constructed. Test plan (one test per plugin suffices):

1. Seed a `:running` run targeting a conversation (same seed helper as Task 1's test). Build an `ai.llm.delta` signal + context whose agent state has that conversation_id. Call `StreamingPlugin.handle_signal(signal, context)` directly. Reload run → `last_heartbeat_at` advanced (sleep 1100ms after seeding to see the change; call `RunLiveness.reset_throttle` first).
2. Same for `ToolEventPlugin.handle_signal` with an `ai.tool.started` signal (this handler returns `{:ok, {:override, ...}}` — assert only on the reloaded run, not the return shape beyond it not raising).

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — `last_heartbeat_at` unchanged.

- [ ] **Step 3: Implement**

In `StreamingPlugin.handle_signal/2`, right after `conversation_id = Helpers.get_conversation_id(agent)`:

```elixir
if signal.type in ["ai.llm.delta", "ai.llm.turn.completed"] do
  Magus.Agents.RunLiveness.touch(conversation_id)
end
```

In `ToolEventPlugin.handle_signal/2`, same position:

```elixir
if signal.type in ["ai.tool.started", "ai.tool.result"] do
  Magus.Agents.RunLiveness.touch(conversation_id)
end
```

Update StreamingPlugin's moduledoc line "Pure signal-to-broadcast translation — NO DB writes, NO state mutations." to state the one exception: a throttled (30s) run-liveness ping.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/run_liveness_touchpoints_test.exs test/magus/agents/plugins`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): liveness pings from streaming and tool activity" -- lib/magus/agents/plugins/streaming_plugin.ex lib/magus/agents/plugins/tool_event_plugin.ex test/magus/agents/run_liveness_touchpoints_test.exs
```

---

### Task 3: Liveness-aware CleanupStale with hard duration cap

**Files:**
- Modify: `lib/magus/agents/agent_run/changes/cleanup_stale.ex`
- Test: extend the existing CleanupStale coverage — grep `test/` for `CleanupStale` / `cleanup_stale` and extend that file; if none exists, create `test/magus/agents/agent_run/cleanup_stale_test.exs`.

**Interfaces:**
- Consumes: `Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{conversation_id}")` (already used in this module), `Magus.Agents.heartbeat_agent_run/2`.
- Produces: a stale-flagged run is reaped ONLY when (a) the target agent process is not alive, OR (b) the run started more than `max_run_duration_minutes` (default 30, from `Application.get_env(:magus, :agents, [])`) ago. Otherwise the run's heartbeat is touched and the reap skipped.

- [ ] **Step 1: Write the failing tests**

The change runs via `after_action` on the `:cleanup_stale` action; tests can invoke it like the Oban worker does — find how existing tests exercise it (grep for `cleanup_stale`); if nothing does, call the action directly: `run |> Ash.Changeset.for_update(:cleanup_stale, %{}, authorize?: false) |> Ash.update!()`. Tests:

1. "reaps when target process is gone" (current behavior preserved): seed `:running` run with stale `last_heartbeat_at` (create + start, then `Repo.update_all` the timestamp back 10 minutes — direct update is fine in tests), target conversation with NO registered agent process. Invoke cleanup. Assert status `:timed_out`.
2. "skips reap and touches heartbeat when process is alive and run is young": register a fake process under the InstanceManager key — read how `maybe_cancel_target` looks up (`InstanceManager.lookup(:conversations, "conv:<id>")`) and how tests elsewhere register test processes with the InstanceManager (grep `test/` for `InstanceManager` usage; e.g. run_orchestrator or e2e support). If test registration is impractical, restructure the change so the liveness decision is a pure function `defp should_reap?(run, process_alive?, now)` and unit-test THAT for the (alive, young) → false / (alive, old) → true / (dead, young) → true matrix, keeping one integration test for the dead-process path. Prefer the pure-function route if registration takes more than a trivial helper.
3. "reaps despite alive process when run exceeds the hard cap": run with `started_at` 31+ minutes ago, process alive (or pure-function variant) → reaped.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — current code always reaps.

- [ ] **Step 3: Implement**

Restructure `change/2`'s after_action:

```elixir
case Ash.get(Magus.Agents.AgentRun, run.id, authorize?: false) do
  {:ok, %{status: :running} = current} ->
    if should_reap?(current, target_process_alive?(current.target_conversation_id), DateTime.utc_now()) do
      reap(current)   # existing body: timeout, cancel, unlink, signal, maybe_start_next
    else
      # Process is alive and the run is within the duration cap: the agent
      # is likely mid-LLM-call between liveness pings. Refresh the
      # heartbeat so the next sweep re-evaluates instead of reaping.
      Logger.info("CleanupStale: skipping reap of run #{current.id}; target process alive")
      Magus.Agents.heartbeat_agent_run(current, authorize?: false)
    end

  _ -> :ok
end
```

```elixir
@default_max_run_duration_minutes 30

defp should_reap?(_run, false = _alive?, _now), do: true

defp should_reap?(%{started_at: %DateTime{} = started_at}, true, now) do
  DateTime.diff(now, started_at, :minute) >= max_run_duration_minutes()
end

defp should_reap?(_run, true, _now), do: false

defp max_run_duration_minutes do
  :magus
  |> Application.get_env(:agents, [])
  |> Keyword.get(:max_run_duration_minutes, @default_max_run_duration_minutes)
end

defp target_process_alive?(nil), do: false

defp target_process_alive?(target_conversation_id) do
  case Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{target_conversation_id}") do
    {:ok, pid} -> Process.alive?(pid)
    :error -> false
  end
rescue
  _ -> false
end
```

Keep the existing reap body verbatim inside a `defp reap(run)`. Update the moduledoc to describe the two-condition reap rule.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/agent_run test/magus/agents/agent_run_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): CleanupStale only reaps dead or over-cap runs" -- lib/magus/agents/agent_run/changes/cleanup_stale.ex test/magus/agents
```

---

### Task 4: Stuck-pending sweep trigger

**Files:**
- Modify: `lib/magus/agents/agent_run.ex` (new calculation, read action, oban trigger)
- Create: `lib/magus/agents/agent_run/changes/sweep_stuck_pending.ex`
- Test: `test/magus/agents/agent_run/sweep_stuck_pending_test.exs` (new)

**Interfaces:**
- Consumes: `RunOrchestrator.maybe_start_next/1`, `Magus.Agents.timeout_agent_run/2`, `AgentRunHelpers.unlink_linked_inbox_events/1`.
- Produces: pending runs older than 15 minutes get a `maybe_start_next` nudge; pending runs older than 6 hours are `:timed_out` + unlinked + `run_failed`-signaled.

- [ ] **Step 1: Write the failing tests**

Invoke the new update action directly (as in Task 3): seed pending runs with backdated `inserted_at` via `Repo.update_all`. Tests:

1. "nudges a 20-minute-old pending run": run stays `:pending` after sweep IF the target has no free capacity path — simpler deterministic assertion: with no InstanceManager registered, `maybe_start_next` claims the run and then requeues it on `registry_unavailable`, leaving it `:pending` again; so assert instead that the sweep function CALLED the nudge path — make the change return distinguishable info via its own action? Keep it simple and honest: assert the run is still not `:timed_out` (nudge ≠ timeout) and (if claiming succeeded transiently) status is back to `:pending`. The meaningful assertions are on the 6h path.
2. "times out a 7-hour-old pending run": status becomes `:timed_out`, linked inbox event (create one with `agent_run_id` = run id) gets unlinked (`agent_run_id == nil`).
3. "leaves a 5-minute-old pending run untouched": sweep read action (`:stuck_pending_runs`) must not even select it — assert via reading the action: `Magus.Agents.AgentRun |> Ash.Query.for_read(:stuck_pending_runs) |> Ash.read!(authorize?: false)` excludes it and includes the 20-minute one.

- [ ] **Step 2: Run tests to verify they fail**

Expected: FAIL — action/calc don't exist.

- [ ] **Step 3: Implement**

In `agent_run.ex`:

```elixir
calculate :is_stuck_pending, :boolean do
  public? false
  calculation expr(status == :pending and inserted_at < ago(15, :minute))
end

read :stuck_pending_runs do
  filter expr(status == :pending and inserted_at < ago(15, :minute))
end

update :sweep_stuck_pending do
  require_atomic? false
  change Magus.Agents.AgentRun.Changes.SweepStuckPending
end
```

New trigger inside the existing `oban do triggers do` block, mirroring `:cleanup_stale_runs` exactly (its own `worker_module_name`/`scheduler_module_name`, `queue :agent_run_cleanup`, `max_attempts 1`), with `scheduler_cron "*/15 * * * *"`, `action :sweep_stuck_pending`, `read_action :stuck_pending_runs`, `worker_read_action :stuck_pending_runs`, `where expr(is_stuck_pending)`.

`sweep_stuck_pending.ex` change module (mirror CleanupStale's structure):

```elixir
@stuck_timeout_hours 6

# after_action:
case Ash.get(Magus.Agents.AgentRun, run.id, authorize?: false) do
  {:ok, %{status: :pending} = current} ->
    if DateTime.diff(DateTime.utc_now(), current.inserted_at, :hour) >= @stuck_timeout_hours do
      Logger.warning("SweepStuckPending: timing out run #{current.id} pending > #{@stuck_timeout_hours}h")
      Magus.Agents.timeout_agent_run(current, authorize?: false)
      Magus.Agents.AgentRunHelpers.unlink_linked_inbox_events(current)
      Magus.Agents.Signals.run_failed(to_string(current.source_conversation_id), %{
        run_id: to_string(current.id),
        status: "timed_out",
        kind: to_string(current.kind),
        objective: String.slice(current.objective || "", 0, 200),
        target_agent_id: current.target_agent_id,
        target_conversation_id: current.target_conversation_id,
        request_id: current.request_id,
        error: "Run stuck in pending"
      })
    else
      # Lost maybe_start_next (e.g. node restart between enqueue and claim):
      # nudge the claim loop; it no-ops when capacity is full.
      Magus.Agents.RunOrchestrator.maybe_start_next(current.target_conversation_id)
    end

  _ -> :ok
end
```

Run `mix ash.codegen sweep_stuck_pending` — expect a no-op or trigger-metadata-only migration (calc + read action need no schema). If AshOban needs its trigger bookkeeping migrated, inspect + `mix ash.migrate` (both dev and `MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test`).

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/agent_run test/magus/agents/agent_run_test.exs test/magus/agents/run_orchestrator_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): sweep stuck pending runs (15m nudge, 6h timeout)" -- lib/magus/agents/agent_run.ex lib/magus/agents/agent_run/changes/sweep_stuck_pending.ex test/magus/agents/agent_run priv/repo/migrations priv/resource_snapshots
```

---

### Task 5: Recovery hardening

**Files:**
- Modify: `lib/magus/agents/recovery.ex`
- Test: `test/magus/agents/recovery_test.exs` (extend)

**Interfaces:**
- Consumes: existing `find_interrupted_message/2`, `Magus.Agents.Dispatcher.dispatch_user_message/1`, `await_agent_ready/1`.
- Produces: recovery (a) aborts (cleanup + `state_change(:idle)`) when the agent never becomes ready, instead of proceeding; (b) skips re-dispatch when a NEWER user message exists in the conversation than the interrupted one (cleanup only, `state_change(:idle)` NOT emitted if the newer message will drive its own turn — emit nothing extra; just log and return).

- [ ] **Step 1: Read, then write the failing tests**

Read `lib/magus/agents/recovery.ex` and `test/magus/agents/recovery_test.exs` fully first; reuse the test file's existing fixtures for conversations/messages. Tests:

1. "skips re-dispatch when a newer user message exists": conversation with interrupted user message M1 (the one `__recovery__.active_message_id` points at... read `find_interrupted_message/2` to determine whether it looks up by active_message_id or last user message) + a NEWER user message M2. Stub/observe dispatch: check how existing recovery tests assert dispatch happened (they may assert on side effects or use the real dispatcher against a test agent). Assert `dispatch_user_message` is NOT invoked for M1 — if the existing tests observe dispatch via the InstanceManager/PubSub, mirror that; otherwise make `recover_interrupted_turn/2` return a tagged result (`{:dispatched, id} | :skipped_newer | :aborted_not_ready | :no_message`) and assert on the return (refactor the async caller to log the result; returning a value from the Task function is free).
2. "aborts when agent never becomes ready": make `await_agent_ready` fail (no agent process for the conversation — likely the default in tests; read how existing tests got past this: if they rely on the 500ms give-up + proceed, the NEW behavior changes them — update those expectations per the new spec: abort instead of proceed). Assert `:aborted_not_ready` return and that streaming-message cleanup still ran.
3. Existing tests keep passing (adjust only where they asserted the old proceed-anyway behavior).

- [ ] **Step 2: Run tests to verify they fail**

Expected: new tests FAIL (no return values / old behavior).

- [ ] **Step 3: Implement**

In `recovery.ex`:

- Change `await_agent_ready/1` exhaustion clause to return `:timeout` instead of `:ok` (keep the log, reword "proceeding anyway" → "aborting recovery").
- `recover_interrupted_turn/2` becomes:

```elixir
defp recover_interrupted_turn(conversation_id, active_message_id) do
  case await_agent_ready(conversation_id) do
    :ok ->
      cleanup_interrupted_messages(conversation_id)
      maybe_redispatch(conversation_id, active_message_id)

    :timeout ->
      cleanup_interrupted_messages(conversation_id)
      Signals.state_change(conversation_id, :idle)
      :aborted_not_ready
  end
rescue
  error ->
    Logger.error("Recovery failed for conversation #{conversation_id}: #{inspect(error)}")
    Signals.state_change(conversation_id, :idle)
    :error
end

defp maybe_redispatch(conversation_id, active_message_id) do
  case find_interrupted_message(conversation_id, active_message_id) do
    {:ok, message} ->
      if newer_user_message_exists?(conversation_id, message) do
        Logger.info(
          "Recovery: newer user message supersedes #{message.id} in #{conversation_id}; skipping re-dispatch"
        )

        :skipped_newer
      else
        Logger.info("Recovery: re-dispatching message #{message.id} for conversation #{conversation_id}")
        Magus.Agents.Dispatcher.dispatch_user_message(message)
        {:dispatched, message.id}
      end

    :error ->
      Logger.warning("Recovery: no user message found for conversation #{conversation_id}")
      Signals.state_change(conversation_id, :idle)
      :no_message
  end
end

defp newer_user_message_exists?(conversation_id, message) do
  require Ash.Query

  Magus.Chat.Message
  |> Ash.Query.filter(
    conversation_id == ^conversation_id and role == :user and
      inserted_at > ^message.inserted_at
  )
  |> Ash.Query.limit(1)
  |> Ash.read!(authorize?: false)
  |> case do
    [] -> false
    _ -> true
  end
rescue
  _ -> false
end
```

(Adapt names/fields to what recovery.ex + Message actually use — verify `role == :user` matches the Message resource's role enum and that `Ash.read!` on Chat.Message with `authorize?: false` is the file's existing convention; if recovery.ex reads messages another way, follow that way.) Keep `maybe_recover/1` (the async Task spawn + `__recovery__` clearing) as is — the newer-message guard inside the task IS the race closure: by the time the task runs, any concurrently-arrived message is visible and wins.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents/recovery_test.exs`
Expected: PASS. Also compile with warnings-as-errors.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): recovery skips superseded turns and aborts when agent unavailable" -- lib/magus/agents/recovery.ex test/magus/agents/recovery_test.exs
```

---

### Task 6: Phase 2 verification sweep

- [ ] **Step 1:** `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors` then `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents test/magus/integrations test/magus/plan` — expect 0 failures.
- [ ] **Step 2:** `mix format` — commit any changes (`chore: format`).
