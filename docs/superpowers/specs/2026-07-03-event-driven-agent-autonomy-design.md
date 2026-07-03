# Event-Driven Agent Autonomy — Design

Date: 2026-07-03
Status: Draft

## Problem

Autonomous custom agents are built around a poll model: inbox events accumulate
and the agent looks at them on its next scheduled heartbeat (default every
360 minutes). The event-driven machinery was designed (the `urgency` field,
budget gates, idempotent enqueue) but never wired together. Investigation on
2026-07-03 verified:

- **`urgency: :immediate` is dead metadata.** It is written by task
  assignment, approval requests, and task completion, but only read for sort
  order (`agent_inbox_event.ex:196`) and a UI badge. No code path enqueues a
  run when an urgent event arrives. An `:immediate` task assignment waits up
  to 6 hours.
- **Only mentions wake an agent immediately.** @mentions dispatch a run
  directly via `InboxEventPlugin` → `RunOrchestrator.enqueue` (a split this
  design keeps: mentions are conversational request-response); everything
  else (assignments, approvals, integration thresholds including LogSource
  crash alerts, which are `urgency: :deferred`) waits for the heartbeat
  cron.
- **The stale-run watchdog kills healthy runs.** A run is reaped when
  `status == :running and last_heartbeat_at < ago(2, :minute)`
  (`agent_run.ex:395`), but `last_heartbeat_at` is set once at claim and only
  ever updated by the `ReportToParent` tool (`report_to_parent.ex:65`), which
  only sub-agents call. Any autonomous run doing more than ~2 minutes of work
  is marked `:timed_out` and its agent cancelled mid-work by the 5-minute
  cleanup cron.
- **Nothing retries; several states stop silently.** Failed heartbeat
  enqueues skip until the next tick (`max_attempts: 1`); failed runs are
  never retried; `:pending` runs are never swept; `expires_at` on inbox
  events is unenforced; dead RSS feeds poll into the void
  (`rss_source.ex:123`); expired credentials fail without notification;
  budget skips, stale timeouts, and recoveries never reach
  `AgentActivityLog`.
- **Recovery races.** `Recovery.maybe_recover` re-dispatches the interrupted
  user message in an async task (`recovery.ex:44`); a concurrently arriving
  message produces two interleaved turns and a duplicate LLM call.

## Goal

A solid foundation for autonomous agent collaboration:

1. **Event-driven first.** Inbox events are the primary wake signal. An
   `:immediate` event wakes the agent within seconds; `:deferred` events wait
   for the digest heartbeat. The heartbeat becomes the fallback timer, not
   the delivery mechanism.
2. **Two intentional paths.** Mentions are conversational request-response:
   direct dispatch, concurrent, the reply appears immediately as a message
   from the mentioned agent in the conversation where the mention happened
   (two agents mentioned, two replies). The inbox is the queue for
   asynchronous work signals only; `AgentRun` is the audit record for both.
3. **Nothing stops silently.** Every skip, timeout, and failure leaves a
   trace; sustained failure escalates to the owner instead of looping or
   going dark.
4. **Holds up over time.** Liveness that doesn't kill healthy work, sweeps
   for every stuck state, retention for every append-only table.

## Decisions

| Decision | Choice |
|---|---|
| Wake model | Event-driven with heartbeat fallback: `:immediate` events enqueue a run at creation; `:deferred` events wait for the scheduled heartbeat |
| New run source | `:inbox_urgent`, treated like `:heartbeat` for gates, preamble, and completion handling |
| Urgent-wake gating | Requires `heartbeat_enabled == true and is_paused == false` (autonomy stays a single opt-in switch) |
| One urgent run per event | Idempotency key `"inbox:<event_id>"`; a failed urgent run is not retried, the event stays pending for the next heartbeat (natural escalation, no loops) |
| Urgent event during in-flight run | Enqueue is rejected (`:already_running`); the completion plugin drains pending `:immediate` events before sleeping |
| Approval responses | On approval match, create an `:approval_response` event (`urgency: :immediate`) carrying the answer, in addition to resolving the `:waiting` event; the urgent-wake path does the rest |
| Run liveness | Throttled `last_heartbeat_at` touches from streaming/tool plugin activity; CleanupStale additionally verifies the target agent process is not alive-and-busy before reaping |
| Budget accounting | `:inbox_urgent` runs count toward `max_daily_runs` alongside `:heartbeat`; spend-budget gate applies |
| Mentions | Stay a direct conversational dispatch path, never touch the inbox: a busy agent must still reply immediately (consult runs are exempt from the in-flight gate), and a mention is not triageable/dismissable like an inbox item; `AgentRun` (`source: :mention`) is their audit record (see §8) |
| Escalation | 3 consecutive failed autonomous runs → owner notification; 10 → auto-pause with visible reason |
| Sweeps/retention | ash_oban triggers per resource (project convention), not a monolithic janitor |

## Design

### 1. Urgent wake path

New change `Magus.Agents.AgentInboxEvent.Changes.TriggerUrgentWake` on the
`:create` action, running in `after_transaction` (enqueue touches other rows,
emits signals, and may dispatch to agent processes; it must not run inside
the event's insert transaction).

Trigger condition: `urgency == :immediate` and the owning agent has
`heartbeat_enabled == true and is_paused == false`.

Enqueue via the existing gate path:

```elixir
RunOrchestrator.enqueue_with_outcome(%{
  kind: :delegate,
  source: :inbox_urgent,
  target_agent_id: event.agent_id,
  target_conversation_id: home_conversation_id,
  initiator_user_id: agent.user_id,
  idempotency_key: "inbox:#{event.id}",
  objective: event.title
})
```

Outcome handling mirrors `HeartbeatScheduler.enqueue_for_agent`:

- `:created` — pre-link the event (`agent_run_id = run.id`) so the existing
  resolve-on-complete / unlink-on-failure machinery applies. Create a
  `HeartbeatEventMessage`-style trace message in the home conversation
  (new source label `:inbox_urgent`).
- `:existing` — no-op (idempotent replay, or the event already got its one
  urgent run).
- `:already_running` — no-op; the drain step (§2) picks the event up when the
  in-flight run completes. Do **not** advance `next_scheduled_at`.
- `:budget_exceeded` / `:insufficient_spend_budget` — log an activity entry
  (§6); the event stays pending for the next heartbeat.
- Errors never fail the event creation; log and continue.

Why not just pull `next_scheduled_at` forward: the heartbeat idempotency key
`"heartbeat:#{agent.id}:#{window}"` allows only one run per interval window
(`heartbeat_scheduler.ex:147`), so an urgent wake inside an already-consumed
window would be deduped away. A distinct source with a per-event key avoids
this and keeps heartbeat semantics untouched.

`RunOrchestrator` changes:

- Add `:inbox_urgent` to the `source` enum on `AgentRun`.
- `check_no_in_flight_autonomous_run/1` and both budget gates match
  `source in [:heartbeat, :manual_trigger, :inbox_urgent]`.
- `check_daily_run_budget/1` counts `:heartbeat` and `:inbox_urgent` runs
  against `max_daily_runs`.

`WakeupPreamble.build/1` handles `:inbox_urgent` with header "You were woken
by an urgent inbox event", rendering the triggering event first, then the
standard inbox/tasks/activity sections and autonomy tools.

`AgentRunCompletionPlugin.ensure_next_scheduled_at/1` applies to
`:inbox_urgent` runs too: an urgent wake must never leave the agent without
a future scheduled heartbeat.

### 2. Drain before sleeping

In `AgentRunCompletionPlugin`, after completing or failing any autonomous run
(`:heartbeat`, `:manual_trigger`, `:inbox_urgent`) and before
`ensure_next_scheduled_at`:

1. Query pending/waiting events for the agent with `urgency == :immediate`
   and `agent_run_id == nil`.
2. If any exist, enqueue an `:inbox_urgent` run keyed on the newest such
   event. The per-event idempotency key guarantees an event whose urgent run
   already happened (and failed without resolving it) does not loop: the key
   returns `:existing` and the event waits for the heartbeat.

This closes the "urgent event arrived while a run was in flight" gap and
gives back-to-back collaboration (agent A assigns a task to agent B while B
is running) low latency without concurrency.

### 3. Urgency classification

- `NotifyAgentAssignment`, `NotifyTaskCompletion`, `RequestApproval`: already
  `:immediate` — now it means something.
- New `:approval_response` event created by `InboxEventPlugin` on approval
  match (`urgency: :immediate`, payload carries the matched option and the
  source conversation), alongside the existing resolution of the `:waiting`
  event. Idempotency key `"approval_response:#{waiting_event.id}"`.
- `LogSource`: events created from `:critical` classifications (crash
  signatures) become `:immediate`; plain error-threshold events stay
  `:deferred`.
- `DataSourceBehaviour`: providers keep declaring urgency in
  `build_inbox_event_attrs/2`; add a per-integration `urgency_override`
  config key (`"immediate" | "deferred" | nil`) so users can promote e.g. a
  status-page RSS feed without a code change.

### 4. Run liveness (fixing the watchdog)

New helper `Magus.Agents.RunLiveness.touch(run_id)`: updates
`last_heartbeat_at` via the existing `:heartbeat` action, throttled to at
most once per 30 seconds per run through an ETS timestamp table (owned by a
small GenServer or `:persistent_term`-guarded table; writes are best-effort,
failures logged at debug).

Touch points (all already receive run correlation or can resolve the active
run for the conversation):

- `StreamingPlugin` on `text.chunk` / `thinking.chunk` batches.
- `ToolEventPlugin` on `tool.start` and `tool.complete`.
- `AgentRunCompletionPlugin` retains final ownership of terminal states.

`CleanupStale` gains a belt-and-braces check before reaping: if the target
conversation's agent process is alive and its strategy reports a busy state,
touch the heartbeat and skip this cycle instead of timing out. Only reap
when the process is gone, idle, or unresponsive.

The 2-minute threshold stays; with real pings it is now correct.

Pending-run sweep: extend the `AgentRun` oban trigger set with a
`:sweep_stuck_pending` trigger. `pending` runs older than 15 minutes get one
`RunOrchestrator.maybe_start_next(target_conversation_id)` nudge (covers
lost `maybe_start_next` calls, e.g. node restart between enqueue and claim);
`pending` runs older than 6 hours are marked `:timed_out` with an activity
entry.

### 5. Recovery hardening

`Recovery.recover_interrupted_turn/2` changes:

- Before re-dispatching, check whether a user message newer than the
  interrupted one exists in the conversation; if so, skip re-dispatch (the
  newer turn supersedes it) and only run the streaming-message cleanup.
- Serialize with normal dispatch: perform the re-dispatch through the agent's
  signal queue (cast to the agent process) rather than the external
  dispatcher path, so an interleaving user message cannot produce two
  concurrent turns.
- If `await_agent_ready/1` exhausts retries, abort recovery (cleanup only,
  state set to idle, activity entry) instead of proceeding blindly.

### 6. Never stop silently

**Activity log coverage.** New `AgentActivityLog` entries (existing resource,
new `activity_type` values): `:wake_urgent`, `:wake_skipped_budget`,
`:wake_skipped_spend`, `:run_timed_out`, `:run_requeued`, `:recovery`,
`:enqueue_error`, `:integration_error`. Every branch in
`HeartbeatScheduler.enqueue_for_agent`, `TriggerUrgentWake`, `CleanupStale`,
and `Recovery` writes one.

**Scheduler watchdog.** New ash_oban trigger on `CustomAgent`
(`:watchdog_overdue`, hourly): agents with
`heartbeat_enabled and not is_paused` whose `next_scheduled_at` is more than
2× their interval in the past get `next_scheduled_at` reset to now (the next
tick picks them up), plus an activity entry and a `Logger.warning`. This
self-heals the `advance_schedule`-failure class and any future scheduling
regression.

**Failure-streak escalation.** After each failed autonomous run,
`AgentRunCompletionPlugin` counts the streak of consecutive
`:error`/`:timed_out` autonomous runs (query, no new fields). At 3, create a
`Magus.Notifications` notification for the owner ("<agent> has failed 3
autonomous runs in a row"); at 10, set `is_paused: true` with a
`pause_reason` (new nullable string attribute on `CustomAgent`, surfaced in
the agent UI) and notify again. Any successful run resets the streak
implicitly.

**Telemetry.** Emit `[:magus, :agents, :run, :enqueued | :started |
:completed | :failed | :timed_out]` and `[:magus, :agents, :wake, :urgent |
:skipped]` telemetry events with `source` metadata, so dashboards/alerts can
attach without further code changes.

### 7. Integration health

`UserIntegration` gains `consecutive_failures :integer default 0`,
`last_error :string`, `last_success_at :utc_datetime`.

- `PollDataSource` and webhook ingestion update these: reset on success,
  increment with the error message on failure. At 10 consecutive failures,
  set integration status `:error`, notify the owner, and stop re-enqueueing
  the poll worker (re-activation from the UI resets the counter and restarts
  polling). RSS distinguishes per-feed failures in `last_error` but tracks
  the counter per integration for v1.
- `ProcessIngestion` logs constraint-violation dedups at `:debug`, real
  errors at `:warning` (today both are `:warning` noise).
- New ash_oban trigger on `Credential` (`:warn_expiry`, daily): credentials
  expiring within 7 days → owner notification; already expired → mark the
  integration `:error` + notify. OAuth refresh, where a refresh token
  exists, is attempted before declaring expiry.
- New ash_oban trigger on `InputMessage` (`:fail_stuck`, every 15 min):
  `:processing` older than 10 minutes → `:failed` with an audit log entry
  (covers `DispatchInput` crashes mid-flight).

### 8. Retention

Mentions explicitly stay out of the inbox. Fan-out is not the reason: one
event per mentioned agent would work, and the in-flight gate is per agent,
so two different agents would still reply concurrently. The real reasons
are same-agent behavior and semantics:

- A mention of an agent that is mid-autonomous-run would be rejected by the
  in-flight gate and wait for the drain step, while the user sits in the
  conversation. Today's `kind: :consult` dispatch is exempt from that gate
  and replies immediately, even mid-run; the same agent mentioned from two
  conversations answers both concurrently.
- The inbox is a discretionary triage queue ("dismiss noise, do work, or
  set your next wakeup"); a mention is a user waiting for a reply and must
  not be dismissable or deferrable. Exempting mention events from the gate
  and pinning their objective would just rebuild the direct path inside the
  inbox wrapper.

`InboxEventPlugin` therefore keeps its direct concurrent dispatch, the
reply appears as a message from each mentioned agent in the source
conversation (`persist_source_response`), and `AgentRun`
(`source: :mention`) remains the audit record.

**Retention (ash_oban triggers, daily):**

- `AgentInboxEvent :expire_due`: enforce `expires_at` (status → `:expired`).
- `AgentInboxEvent :prune_terminal`: destroy `resolved | dismissed |
  expired` events older than 30 days.
- `AgentRun :prune_terminal`: destroy terminal runs older than 90 days
  (inbox events referencing them are pruned first / FK nilifies).
- `AgentActivityLog :prune_old`: destroy entries older than 90 days.
- `IntegrationConversation`: cleanup on integration deactivation and
  conversation deletion (cascade change on those destroy actions).

## Phases

**Phase 1 — Event-driven wake.** `:inbox_urgent` source + gates,
`TriggerUrgentWake`, drain-before-sleep, `:approval_response` events,
LogSource urgency, `urgency_override` config, `WakeupPreamble` support,
trace messages. *Delivers: urgent events wake agents in seconds.*

**Phase 2 — Liveness and recovery.** `RunLiveness.touch` + plugin touch
points, liveness-aware `CleanupStale`, pending-run sweep, recovery
serialization + newer-message guard + abort-on-not-ready. *Delivers: long
runs survive; no interleaved recovery turns.*

**Phase 3 — Never silent.** Activity-log coverage, scheduler watchdog,
failure-streak notifications + auto-pause (`pause_reason`), telemetry,
integration failure counters, credential expiry, `InputMessage` sweep.
*Delivers: every failure visible, sustained failure escalates.*

**Phase 4 — Retention.** All retention triggers, `expires_at` enforcement,
`IntegrationConversation` cleanup. *Delivers: bounded tables.*

Each phase is independently shippable; Phases 1 and 2 are the reliability
core and should land first, in either order.

## Testing

Per phase, plus the currently-missing scary paths:

- Urgent wake: `:immediate` event → run enqueued with correct key; second
  create with same key → no duplicate; event during in-flight run → drained
  at completion; failed urgent run → event pending, no re-enqueue loop;
  paused/disabled agent → no wake; budget-exceeded → activity entry, event
  survives.
- Approval: user approval → `:approval_response` event → urgent run wakes
  the requesting agent.
- Liveness: simulated long run with tool/stream activity survives two
  CleanupStale cycles; run with dead agent process is reaped; alive-and-busy
  process is not reaped even with stale timestamp.
- Pending sweep: orphaned `:pending` run (no `maybe_start_next`) is claimed
  by the nudge; 6-hour-old pending run is timed out.
- Recovery: interrupted turn with a newer user message → no re-dispatch;
  recovery + concurrent message → single turn.
- Watchdog: overdue agent gets rescheduled + logged.
- Streaks: 3 failures → notification; 10 → paused with reason; success
  resets.
- Integrations: 10 consecutive RSS failures → integration `:error` + poll
  stopped + notification; reactivation resumes.
- Retention: prunes respect age cutoffs and never touch active rows.

## Out of scope

- Priority ordering between queued runs of different sources (FIFO within
  `max_parallel_runs_per_target` stays).
- LLM-call idempotency keys (worth doing, but orthogonal; tracked
  separately).
- Multi-node scheduler fairness beyond the existing advisory-lock claiming.
- Knowledge-sync webhook implementation (`webhook_controller.ex:125` stub).
- Cross-agent scheduling optimization (batching multiple agents' wakes).
