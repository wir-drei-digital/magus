# Event-Driven Autonomy Phase 3: Never Silent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every autonomous-agent skip, timeout, and failure leaves a queryable trace; sustained failure escalates to the owner (notify at 3, auto-pause at 10); integrations and credentials fail loudly instead of decaying silently.

**Architecture:** Extend `AgentActivityLog` coverage into every silent branch; add telemetry events at run lifecycle points; an hourly watchdog self-heals overdue schedules; a failure-streak module shared by the completion plugin and the stale reaper escalates via `Magus.Notifications`; `UserIntegration` gains health counters driven by polling/ingestion; ash_oban triggers warn on credential expiry and fail stuck InputMessages. Spec: `docs/superpowers/specs/2026-07-03-event-driven-agent-autonomy-design.md` §6–§7.

**Tech Stack:** Elixir/Phoenix, Ash 3.x + AshPostgres + ash_oban, `:telemetry`, ExUnit + `Magus.Generators`.

## Global Constraints

- Never `mix ash.reset`. Schema changes via `mix ash.codegen <name>` + `mix ash.migrate` on dev AND test partition (`MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix ash.migrate`, env sourced).
- All test commands: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test <path>`.
- Activity entries and notifications are best-effort side effects: rescue + `Logger.warning`, never break the calling flow.
- Activity log writes go through `Magus.Agents.create_activity_log(attrs, authorize?: false)` (existing interface, see `activity_log_plugin.ex:292` for the attrs shape — read it and mirror; entries need `agent_id`, `user_id`, `activity_type`, `summary`, optional metadata).
- New `activity_type` values (exact atoms): `:wake_urgent`, `:wake_skipped`, `:run_timed_out`, `:watchdog_reset`, `:recovery`, `:integration_error`. (`:run_failed`, `:error` already exist — reuse, don't duplicate.)
- Notifications via `Magus.Notifications.create_notification(attrs, authorize?: false)` — read `lib/magus/notifications/` resource for required attrs and an existing caller for the pattern.
- Telemetry event names (exact): `[:magus, :agents, :run, :enqueued | :started | :completed | :failed | :timed_out]` and `[:magus, :agents, :wake, :urgent | :skipped]`, measurements `%{count: 1}`, metadata at minimum `%{source: run.source (atom or nil), target_agent_id: ...}`.
- Escalation thresholds: notify owner at 3 consecutive failed autonomous runs, auto-pause + notify at 10. Streak = consecutive `:error`/`:timed_out` terminal autonomous runs (sources `[:heartbeat, :manual_trigger, :inbox_urgent]`), newest first; any `:complete` breaks it.
- Integration failure threshold: 10 consecutive failures → status `:error` + owner notification + polling stops.
- Commit per task with explicit paths after `--`.

---

### Task 1: Activity-log coverage for silent branches

**Files:**
- Modify: `lib/magus/agents/agent_activity_log.ex` (extend `activity_type` one_of, ~line 102)
- Modify: `lib/magus/agents/workers/heartbeat_scheduler.ex` (skip branches)
- Modify: `lib/magus/agents/agent_inbox_event/changes/trigger_urgent_wake.ex` (`:created` + budget-skip branches)
- Modify: `lib/magus/agents/agent_run/changes/cleanup_stale.ex` (reap path)
- Modify: `lib/magus/agents/agent_run/changes/sweep_stuck_pending.ex` (timeout path)
- Modify: `lib/magus/agents/recovery.ex` (recovery outcomes)
- Create: `lib/magus/agents/support/autonomy_trace.ex` (shared helper)
- Test: `test/magus/agents/autonomy_trace_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Agents.Support.AutonomyTrace.log(agent_id, user_id, activity_type, summary, metadata \\ %{})` — nil-safe (`agent_id` or `user_id` nil → no-op), never raises, writes an AgentActivityLog entry. All call sites below use it. Task 3/4/5 reuse it.

- [ ] **Step 1: Write the failing tests** — for AutonomyTrace itself (writes entry with the new types; nil agent_id no-op; never raises on bogus input) and one integration-style test per call site where cheap: heartbeat budget skip (drive `HeartbeatScheduler.enqueue_for_agent` indirectly via `tick()` with an over-budget agent — mirror existing heartbeat scheduler tests, grep for the existing budget-skip test and extend it to also assert an activity entry with `activity_type == :wake_skipped`), TriggerUrgentWake `:created` (extend an existing trigger_urgent_wake test to assert a `:wake_urgent` entry), CleanupStale reap (extend the existing dead-process reap test: assert `:run_timed_out` entry), SweepStuckPending 7h timeout (same pattern), Recovery `:aborted_not_ready` (extend existing test: assert `:recovery` entry with metadata outcome).

- [ ] **Step 2: Run to verify failures.**

- [ ] **Step 3: Implement.** Add the new enum values. AutonomyTrace:

```elixir
defmodule Magus.Agents.Support.AutonomyTrace do
  @moduledoc """
  Best-effort AgentActivityLog writes from autonomy machinery (scheduler,
  urgent wakes, sweeps, recovery). Never raises; nil ids no-op — silent
  branches must stay observable without becoming fragile.
  """

  require Logger

  def log(agent_id, user_id, activity_type, summary, metadata \\ %{})
  def log(nil, _user_id, _type, _summary, _metadata), do: :ok
  def log(_agent_id, nil, _type, _summary, _metadata), do: :ok

  def log(agent_id, user_id, activity_type, summary, metadata) do
    case Magus.Agents.create_activity_log(
           %{
             agent_id: agent_id,
             user_id: user_id,
             activity_type: activity_type,
             summary: summary,
             metadata: metadata
           },
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("AutonomyTrace: log failed (#{activity_type}): #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("AutonomyTrace: log crashed (#{activity_type}): #{Exception.message(e)}")
      :ok
  end
end
```

(Verify the create action's accepted attrs by reading `agent_activity_log.ex` + `activity_log_plugin.ex:280-300`; adapt attr names — e.g. if the resource wants `details` instead of `metadata`, follow the resource.)

Call sites (each one line + summary string):
- HeartbeatScheduler: `:skipped_budget` → `AutonomyTrace.log(agent.id, user.id, :wake_skipped, "Heartbeat skipped: daily run budget exhausted", %{reason: "budget_exceeded", used: ..., limit: ...})`; `:skipped_spend_budget` → same with reason "insufficient_spend_budget"; generic enqueue `{:error, reason}` → `:wake_skipped` with the inspected reason. Do NOT log `:already_running` or `:existing` (routine no-ops).
- TriggerUrgentWake: `:created` → `:wake_urgent` ("Urgent wake for inbox event: <title>", %{event_id: ...}); budget-error branch → `:wake_skipped` with reason + event_id.
- CleanupStale `reap/1`: `:run_timed_out` ("Run timed out: no liveness for 2m", %{run_id, source, objective-slice}) — use `run.target_agent_id`/`run.initiator_user_id` (nil-safe no-op covers non-agent runs).
- SweepStuckPending timeout branch: `:run_timed_out` ("Run stuck in pending > 6h", %{run_id, source}).
- Recovery: after `recover_interrupted_turn` resolves, log `:recovery` with the outcome tag ("Recovery: <outcome>" + %{outcome: ...}) — recovery has conversation_id, not agent_id/user_id; look at how Recovery could resolve the agent: it can't cheaply (conversation agents aren't CustomAgents) — SO: for Recovery only, skip AutonomyTrace and instead keep `Logger` (already present) UNLESS the conversation belongs to a custom agent home conversation; determining that is out of scope — RESOLUTION: drop the Recovery call site from this task; note it in the report as intentionally skipped (Recovery is user-conversation machinery, not agent-scoped; its Logger lines are the trace).

- [ ] **Step 4: Run tests** (`test/magus/agents` scoped files you touched + new file). Compile with warnings-as-errors. `mix ash.codegen --check` — atom enum additions need no migration; if codegen disagrees, generate + inspect + migrate both DBs.

- [ ] **Step 5: Commit** — `feat(agents): activity-log trace for silent autonomy branches` with explicit paths.

---

### Task 2: Telemetry events at run lifecycle points

**Files:**
- Create: `lib/magus/agents/telemetry.ex`
- Modify: `lib/magus/agents/run_orchestrator.ex` (enqueued after find_or_create :created; started in start_claimed_run success)
- Modify: `lib/magus/agents/plugins/agent_run_completion_plugin.ex` (completed/failed)
- Modify: `lib/magus/agents/agent_run/changes/cleanup_stale.ex` + `sweep_stuck_pending.ex` (timed_out)
- Modify: `lib/magus/agents/agent_inbox_event/changes/trigger_urgent_wake.ex` (wake urgent/skipped)
- Test: `test/magus/agents/telemetry_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Agents.Telemetry.run_event(:enqueued | :started | :completed | :failed | :timed_out, run)` and `Magus.Agents.Telemetry.wake_event(:urgent | :skipped, %{target_agent_id: ..., source: ...})` emitting the exact event names from Global Constraints via `:telemetry.execute/3`; never raises.

- [ ] **Step 1: Failing tests** — attach a telemetry handler in the test (`:telemetry.attach_many` to a self()-message forwarder, detach in on_exit), call `Telemetry.run_event(:completed, run_struct_or_map)`, assert the message with event name + metadata. One test asserting integration: enqueue a run via RunOrchestrator and assert `[:magus, :agents, :run, :enqueued]` fired.

- [ ] **Step 2–3:** Implement the module (thin wrappers, rescue-all) and add one call per site listed. Keep metadata small: `%{source:, target_agent_id:, run_id:, kind:}` (stringify ids).

- [ ] **Step 4: Run tests + compile.**

- [ ] **Step 5: Commit** — `feat(agents): telemetry for run lifecycle and wakes`.

---

### Task 3: Scheduler watchdog (overdue self-heal)

**Files:**
- Modify: `lib/magus/agents/custom_agent.ex` (read action `:watchdog_overdue_agents`, update action `:watchdog_reset_schedule`, oban trigger)
- Create: `lib/magus/agents/custom_agent/changes/watchdog_reset.ex`
- Test: `test/magus/agents/custom_agent/watchdog_test.exs` (new)

**Interfaces:**
- Consumes: `AutonomyTrace.log/5` (Task 1).
- Produces: hourly trigger that finds agents with `heartbeat_enabled and not is_paused` whose `next_scheduled_at` is older than 2× their interval, resets `next_scheduled_at` to now, logs `:watchdog_reset` activity + `Logger.warning`.

- [ ] **Step 1: Failing tests** — read action selects an agent overdue by 2× its interval (backdate `next_scheduled_at` via the `:set_next_scheduled_at` action with a past datetime — it accepts arbitrary datetimes), excludes: a merely-due agent (overdue < 2× interval), paused, heartbeat-disabled, and `next_scheduled_at: nil` agents. Update action resets `next_scheduled_at` to ~now and writes the activity entry.

- [ ] **Step 2–3:** Implement. The overdue filter needs per-row interval math — use a fragment:

```elixir
read :watchdog_overdue_agents do
  filter expr(
    heartbeat_enabled == true and
      is_paused == false and
      not is_nil(next_scheduled_at) and
      fragment(
        "? < (now() at time zone 'utc') - (interval '1 minute' * ? * 2)",
        next_scheduled_at,
        heartbeat_default_interval_minutes
      )
  )
end
```

(`heartbeat_default_interval_minutes` has default 360 and min 5, non-nil — verify; if nullable in DB, coalesce in the fragment.) Update action `:watchdog_reset_schedule` with `require_atomic? false`, change module sets `next_scheduled_at` to `DateTime.utc_now()` and in `after_action` logs `Logger.warning` + `AutonomyTrace.log(agent.id, agent.user_id, :watchdog_reset, "Watchdog reset overdue heartbeat schedule", %{was: <old value>})`. Oban trigger mirrors the AgentRun trigger pattern (own worker/scheduler names, `max_attempts 1`) with `scheduler_cron "0 * * * *"`, `read_action`/`worker_read_action :watchdog_overdue_agents`, and a `where expr(...)` — AshOban `where` needs a calculation or inline expr; mirror how AgentRun uses `where expr(is_stale)` by adding a private `:is_watchdog_overdue` calculation with the same fragment. Run codegen (expect no schema migration; trigger bookkeeping only) + migrate both DBs if generated.

- [ ] **Step 4: Run tests + compile.**

- [ ] **Step 5: Commit** — `feat(agents): hourly watchdog self-heals overdue heartbeat schedules`.

---

### Task 4: Failure-streak escalation (notify at 3, pause at 10)

**Files:**
- Modify: `lib/magus/agents/custom_agent.ex` (new `pause_reason :string` attribute, nullable, public; accepted by an internal update action `:pause_for_failures` setting `is_paused: true` + `pause_reason`; ALSO ensure existing unpause/resume action clears `pause_reason` — find the action that sets `is_paused: false` and add the clear)
- Create: `lib/magus/agents/support/failure_streak.ex`
- Modify: `lib/magus/agents/plugins/agent_run_completion_plugin.ex` (call after fail_run for autonomous runs)
- Modify: `lib/magus/agents/agent_run/changes/cleanup_stale.ex` (call after reap when target_agent_id present)
- Migration: `mix ash.codegen add_custom_agent_pause_reason` (+ migrate both DBs)
- Test: `test/magus/agents/failure_streak_test.exs` (new)

**Interfaces:**
- Consumes: `AutonomyTrace.log/5`, `Magus.Notifications.create_notification/2`.
- Produces: `Magus.Agents.Support.FailureStreak.check_and_escalate(agent_id)` — computes the consecutive-failure streak, at exactly 3 notifies the owner, at >= 10 pauses the agent (`pause_reason: "Auto-paused after 10 consecutive failed autonomous runs"`) + notifies; returns `{:ok, streak}`; never raises.

- [ ] **Step 1: Failing tests** — seed terminal autonomous runs for an agent in controlled order (create + start + fail/complete via existing interfaces; the `inserted_at`/`completed_at` ordering — read how streak query sorts and backdate accordingly with Repo.update_all):
  1. streak 3 (3 failed, then older complete) → notification created for owner (assert via Notifications read), agent NOT paused.
  2. streak 2 → no notification.
  3. streak 4 → NO new notification (only fire at exactly 3 — dedupe rule).
  4. streak 10 → paused with pause_reason + notification.
  5. newest run complete → streak 0, no action even with 10 older failures.
  6. mixed sources: `:mention` failures do NOT count.

- [ ] **Step 2–3:** Implement:

```elixir
defmodule Magus.Agents.Support.FailureStreak do
  @moduledoc """
  Escalates sustained autonomous-run failure: owner notification at exactly
  3 consecutive failures (exactly, so repeats don't spam), auto-pause with
  a visible reason at 10. A completed run resets the streak implicitly.
  """

  require Ash.Query
  require Logger

  alias Magus.Agents.Support.AutonomyTrace

  @autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]
  @notify_at 3
  @pause_at 10
  @scan_limit 15

  def check_and_escalate(nil), do: {:ok, 0}

  def check_and_escalate(agent_id) do
    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(
        target_agent_id == ^agent_id and
          source in ^@autonomous_sources and
          status in [:complete, :error, :timed_out]
      )
      |> Ash.Query.sort(completed_at: :desc)
      |> Ash.Query.limit(@scan_limit)
      |> Ash.read!(authorize?: false)

    streak = runs |> Enum.take_while(&(&1.status in [:error, :timed_out])) |> length()

    cond do
      streak >= @pause_at -> pause(agent_id, streak)
      streak == @notify_at -> notify(agent_id, streak)
      true -> :ok
    end

    {:ok, streak}
  rescue
    e ->
      Logger.warning("FailureStreak: check failed for #{agent_id}: #{Exception.message(e)}")
      {:ok, 0}
  end

  # pause/2, notify/2: read the agent (authorize?: false); pause via the
  # :pause_for_failures action (idempotent: skip if already is_paused);
  # both write an AutonomyTrace entry (:error type with metadata) and a
  # Magus.Notifications.create_notification for agent.user_id — read the
  # Notification resource for required attrs (title/body/kind/link etc.)
  # and mirror an existing caller.
end
```

Note `completed_at` sort: `:timed_out` runs — verify the `:timeout` action sets `completed_at`; if not (read `agent_run.ex:111-117`), sort by `updated_at: :desc` instead and say so in the report. Call `FailureStreak.check_and_escalate(failed_run.target_agent_id)` in the plugin's `fail_run/2` (autonomous sources only) after `unlink_linked_inbox_events`, mirrored into `handle_run_failed/2`; and in CleanupStale's `reap/1` + SweepStuckPending's timeout branch after the timeout call.

- [ ] **Step 4: Run tests + compile; codegen migration for pause_reason committed with snapshots.**

- [ ] **Step 5: Commit** — `feat(agents): failure-streak escalation with auto-pause`.

---

### Task 5: Integration health counters

**Files:**
- Modify: `lib/magus/integrations/user_integration.ex` (attributes `consecutive_failures :integer default 0`, `last_error :string nullable`, `last_success_at :utc_datetime_usec nullable`; update actions `:record_poll_success`, `:record_poll_failure`, `:mark_errored`)
- Modify: `lib/magus/integrations/workers/poll_data_source.ex` (drive counters; stop re-enqueue at threshold)
- Modify: `lib/magus/integrations/process_ingestion.ex` (log-level split: dedup/constraint errors → debug)
- Migration: `mix ash.codegen add_integration_health_fields`
- Test: `test/magus/integrations/integration_health_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.Notifications.create_notification/2`.
- Produces: polling failures increment `consecutive_failures` + set `last_error`; success resets to 0 + `last_success_at`; at 10 consecutive failures the integration status becomes `:error`, the owner is notified once, and the poll worker does NOT re-enqueue. Re-activation (existing action that sets status back to `:active` — find it) resets the counters.

- [ ] **Step 1: Read first.** `poll_data_source.ex` end-to-end: how it loads the integration, calls `provider.poll/2`, records sync, re-enqueues. Determine the failure signal: does `poll/2` return `{:error, _}`, raise, or swallow (RSS returns entries and logs failures per-feed)? Then decide with this rule: a poll attempt is a FAILURE iff `poll/2` raises OR returns `{:error, _}` OR (RSS-specific) returns zero entries while every configured feed errored — for the RSS case, change `RssSource.poll/2` to return `{:ok, entries}` / `{:error, :all_feeds_failed}` (or count failures internally and return the tuple the worker expects — match the DataSource behaviour's callback contract, updating the behaviour + the other provider if the contract changes; keep the change minimal and mechanical).

- [ ] **Step 2: Failing tests** — drive the worker's perform with a stubbed/broken integration config (e.g. RSS with an unreachable feed URL — tests must not hit the network: use an invalid scheme or 127.0.0.1:1 style URL with a short timeout; check what Req does offline and keep the test deterministic; if network-dependence can't be avoided, test the counter actions + threshold logic directly instead and say so): failure increments; success resets; 10th failure sets status `:error` + notification + no re-enqueued Oban job (assert via Oban testing helpers — check how existing worker tests assert enqueues).

- [ ] **Step 3: Implement.** Counter updates via the new update actions (`authorize?: false` from the worker). Threshold check inside the failure path; notification exactly once (fire when transitioning INTO `:error`, not on every subsequent failure — the stop-re-enqueue makes repeats moot anyway). Re-enqueue skip: after recording failure, only `Oban.insert` the next poll if integration still active. Reset on the existing re-activation action via a small change (clear counters + `last_error`).

- [ ] **Step 4: Run `test/magus/integrations` + compile; migrate both DBs; commit with migration + snapshots.**

- [ ] **Step 5: Commit** — `feat(integrations): failure counters, auto-error at 10, quieter dedup logs`.

---

### Task 6: Credential expiry warnings + stuck InputMessage sweep

**Files:**
- Modify: `lib/magus/integrations/credential.ex` (oban trigger `:warn_expiring`, daily; read action `:expiring_soon`; update action `:process_expiry_warning` + change module)
- Create: `lib/magus/integrations/credential/changes/process_expiry_warning.ex`
- Modify: `lib/magus/integrations/input_message.ex` (oban trigger `:fail_stuck`, cron `*/15 * * * *`; read action `:stuck_processing`; update action `:fail_stuck_message`)
- Migration: codegen if triggers require it
- Test: `test/magus/integrations/credential_expiry_test.exs`, `test/magus/integrations/input_message_sweep_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.Notifications.create_notification/2`.
- Produces: credentials with `expires_at` within 7 days → owner notified (once per credential per window — use a `metadata`/flag field if one exists, else notify on each daily tick within the window is acceptable IF you note it; prefer a `expiry_warned_at :utc_datetime_usec` attribute added in this task's migration, set on first warn, cleared if `expires_at` changes — implement the attribute route); already-expired credentials → linked integration `:mark_errored` + notification. InputMessages in `:processing` with `updated_at` older than 10 minutes → `:failed`.

- [ ] **Step 1: Read** `credential.ex` (fields: `expires_at` exists per exploration; relationship to UserIntegration) and `input_message.ex` (status enum has `:failed`; verify a transition action exists or add `:fail_stuck_message`). OAuth refresh: check whether any provider module exports a refresh callback (grep `refresh` under lib/magus/integrations/providers/); if none exists, do NOT invent one — note in the change module doc that refresh-before-warn is a future hook.

- [ ] **Step 2: Failing tests** — expiring-soon selection (7d window in, 8d out, nil out, already-warned out), warn sets `expiry_warned_at` + notification, expired marks integration errored + notifies, stuck InputMessage (backdated `updated_at`, status `:processing`) → `:failed`; fresh `:processing` untouched.

- [ ] **Step 3: Implement** with ash_oban triggers mirroring the established pattern (own worker/scheduler names, max_attempts 1, `where expr(...)` on private calculations). Daily cron for credentials (`"0 6 * * *"`), 15-min for input messages.

- [ ] **Step 4: Run tests + compile; codegen (expiry_warned_at migration) + migrate both DBs.**

- [ ] **Step 5: Commit** — `feat(integrations): credential expiry warnings and stuck input-message sweep`.

---

### Task 7: Phase 3 verification sweep

- [ ] **Step 1:** `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`, then full `MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents test/magus/integrations test/magus/plan test/magus/notifications` (if the notifications dir exists) — 0 failures.
- [ ] **Step 2:** `mix format` + commit if changed.
