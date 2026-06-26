# Agent Control Plane

> **Note**: This document describes the post-redesign architecture as
> of 2026-04. The old triage layer (`TriageAgent`, `TriageStrategy`,
> `TriagePlugin`) was removed; see commit history for the migration.

How the platform tracks agent awareness, decisions, and execution
through a unified inbox, activity log, and a single run plane.

## Overview

Custom agents are autonomous through the existing run plane. Every
executable unit of agent work is an `AgentRun`, enqueued via
`RunOrchestrator`. Heartbeat-initiated work follows the same path
as @mentions and sub-agent spawns; only the `source` label differs.

The control plane answers five questions the platform could not
answer before:

1. **What woke this agent up?** AgentInboxEvent + AgentRun.source
2. **What work exists and who owns it?** Plan.Task with agent assignment
3. **Why is this task blocked?** Task `:blocked` status + `blocked_reason`
4. **What did the agent decide and why?** AgentActivityLog + visible
   `:event` messages in the home conversation
5. **How can the user intervene?** Control room UI with "Open
   conversation" links and a "Run now" button

## Three-Layer Architecture

```
┌─────────────────────────────────────────────────────┐
│                    User Surface                      │
│    Control room, agent detail, task pane, chat       │
├─────────────────────────────────────────────────────┤
│              Commitment Layer (Plan.Task)             │
│     What work exists, who owns it, what's blocked    │
├─────────────────────────────────────────────────────┤
│            Awareness Layer (Agents domain)            │
│  AgentInboxEvent → AgentRun → AgentActivityLog       │
├─────────────────────────────────────────────────────┤
│           Execution Layer (Jido Runtime)              │
│     ConversationAgent (ReAct) + autonomy tools       │
├─────────────────────────────────────────────────────┤
│            Workspace Layer (Sandbox)                  │
│         Per-conversation sandboxed execution          │
└─────────────────────────────────────────────────────┘
```

### Technology Layer Boundaries

| Layer | Framework | Role |
|-------|-----------|------|
| **Agent Runtime** | **Jido** | `ConversationAgent` with `ReactStrategy`, plugins, signals. One execution path for all wakeup sources. |
| **Persistence** | **Ash** | Resources (AgentInboxEvent, AgentActivityLog, AgentRun, etc.). Accessed from Jido via plugins and actions. |
| **Scheduling** | **Oban (ash_oban)** | `HeartbeatScheduler` cron worker polls per-agent due times and enqueues runs. Survives hibernation and server restarts. |
| **UI** | **Phoenix LiveView** | Consumes PubSub streams and reads Ash resources. No agent logic in LiveViews. |

**Key principle**: There is no longer a separate triage agent. The
core agent loop (sense → decide → act) runs entirely in
`ConversationAgent`. Ash is the data layer. Phoenix observes via
PubSub. Oban handles wakeup scheduling and other non-agent
background work.

## Wakeup sources

Every wake-up flows through `RunOrchestrator.enqueue/1`. The
`AgentRun.source` attribute records what woke the agent:

| Source | Mechanism | `source` label | Notes |
|---|---|---|---|
| User message in home conversation | Direct `ConversationAgent` turn | n/a | No `AgentRun` |
| @mention | `InboxEventPlugin` → `RunOrchestrator` | `:mention` | |
| Sub-agent spawn | `SpawnSubAgent` tool → `RunOrchestrator` | `:sub_agent_spawn` | |
| Heartbeat (per-agent cadence) | `HeartbeatScheduler` Oban cron → `RunOrchestrator` | `:heartbeat` | Subject to budget gates |
| Manual "Run now" button | UI → `RunOrchestrator` | `:manual_trigger` | User-initiated, bypasses heartbeat budgets |

## Heartbeat scheduling

Per-agent cadence is configured via
`CustomAgent.heartbeat_default_interval_minutes`. The
`HeartbeatScheduler` Oban worker (cron: every 5 minutes) does the
following:

1. Finds agents where `heartbeat_enabled and not is_paused and (next_scheduled_at IS NULL or next_scheduled_at <= now)`.
2. For each due agent, enqueues an `AgentRun` with
   `source: :heartbeat` via `RunOrchestrator.enqueue/1`. The target
   conversation is the agent's home conversation.
3. On successful enqueue: writes a "Heartbeat started" `:event`
   message in the home conversation (via
   `Magus.Agents.HeartbeatEventMessage`).
4. On rejection: writes a "Heartbeat skipped" event message and
   advances `next_scheduled_at` so the next cron tick reconsiders
   the agent.

The `next_scheduled_at` field on `CustomAgent` enables absolute
datetime scheduling. The default interval serves as the fallback
cadence when the agent does not call `set_next_wakeup`.

### Skip reasons

`RunOrchestrator.enqueue/1` may reject a heartbeat run for any of:

- `:already_running`: a prior heartbeat run for this agent is still
  `:pending` or `:running` (in-flight dedup).
- `:budget_exceeded`: `CustomAgent.max_daily_runs` (24h rolling
  window over `:heartbeat` source runs) reached.
- `:insufficient_credits`: owner's usage-plan credits exhausted
  (`LimitEnforcer.check_daily_credits/1`).

`:manual_trigger` bypasses the daily-runs and credit gates
(user-initiated work is always allowed) but still respects in-flight
dedup.

## Wakeup execution

When a `:heartbeat` or `:manual_trigger` `AgentRun` claims:

1. The Builder synthesizes a wakeup system-prompt preamble (current
   time, default interval, last successful wake-up, inbox stats,
   open tasks, recent activity, brain context, tool hints) via
   `Magus.Agents.Context.WakeupPreamble` and prepends it to the
   agent's normal system prompt.
2. `ConversationAgent` runs its normal ReAct loop with its full
   tool set plus three autonomy-only tools:
   - `list_inbox_events()`: lists pending events
   - `dismiss_event(event_id, reason)`: resolves an event without
     follow-up
   - `set_next_wakeup(at:, reason:)`: overrides
     `CustomAgent.next_scheduled_at`
3. On run completion, `AgentRunCompletionPlugin`:
   - Resolves linked `AgentInboxEvent`s (those with
     `agent_run_id == run.id`), marking them
     `resolved_by: :run_completed`.
   - Sets `next_scheduled_at` to the default interval if
     `set_next_wakeup` was not called (heartbeat only;
     `:manual_trigger` does not advance the schedule).
4. On run failure, linked events are unlinked (`agent_run_id` set
   back to `nil`) so the next heartbeat can reconsider them.

## Budget enforcement

All gates live at `RunOrchestrator.enqueue/1`:

| Limit | Applies to | Source |
|---|---|---|
| `max_daily_runs` | `:heartbeat` only | `CustomAgent.max_daily_runs` (nil/0 = unlimited) |
| `max_tokens_per_run` | every `AgentRun` | `CustomAgent.max_tokens_per_run` (`TokenAccumulator` stop condition; runner integration is a follow-up) |
| Usage-plan credits | `:heartbeat` runs | `LimitEnforcer.check_daily_credits/1` |

`:manual_trigger` and `:mention` runs bypass `max_daily_runs` and
the credit check; they still respect `max_tokens_per_run` once the
runner integration lands.

## AgentInboxEvent

Universal input. Every trigger that needs agent awareness enters as
an inbox event.

### Event types

| Type | Urgency | Source | Example |
|------|---------|--------|---------|
| `:mention` | `:immediate` | `:conversation` | User @mentions agent in chat |
| `:task_assigned` | `:immediate` | `:system` | Plan.Task assigned to agent |
| `:approval_response` | `:immediate` | `:conversation` | Agent requests human approval |
| `:content` | `:deferred` | `:integration` | RSS/email content item |
| `:integration` | varies | `:integration` | External service event |
| `:agent_message` | `:immediate` | `:agent` | Message from another agent |
| `:system` | `:deferred` | `:system` | Platform-level notification |

### Status lifecycle

```
:pending → :processing → :resolved
                       → :dismissed
                       → :expired
```

The `:waiting` status remains for approval events; the legacy
"defer" use case has been removed. "Wait until X" is now expressed
as a `Plan.Task` with a due date.

### Run linkage

`AgentInboxEvent.agent_run_id` (nullable, ON DELETE SET NULL) links
an event to the `AgentRun` currently working on it. Resolution
paths:

- `dismiss_event` tool: event resolved with `resolved_by: :agent`.
- Linked to a successful run: event resolved with
  `resolved_by: :run_completed`.
- Linked to a failed run: `agent_run_id` cleared, status remains
  `:pending` (the next heartbeat reconsiders it).

### Deduplication

- `unique_idempotency`: `(agent_id, idempotency_key)` scoped to
  non-terminal statuses (`pending`, `waiting`, `processing`).
- `unique_content_hash`: `(agent_id, content_hash)` for content
  dedup.

### Key files

- `lib/magus/agents/agent_inbox_event.ex`: Ash resource
- Domain interfaces in `lib/magus/agents.ex`

## AgentActivityLog

Universal output. Append-only audit trail of everything the agent
decided or did. Includes `model_used`, `tokens_used`,
`estimated_cost_usd`, and `duration_ms` for cost monitoring.

### Key file

- `lib/magus/agents/agent_activity_log.ex`

## Visible trace

Each wake-up produces a single `:event` message in the home
conversation, mirroring the jobs pattern. The message transitions
through `running` → `complete | skipped | failed`:

| Stage | Text |
|---|---|
| running | "Heartbeat started at <time>" / "Manual wake-up triggered by <user>" |
| complete | "Heartbeat completed: dismissed N event(s); next at <time>" |
| skipped (in-flight) | "Heartbeat skipped: previous wake-up still running" |
| skipped (budget) | "Heartbeat skipped: daily run cap reached (N/N)" |
| skipped (credits) | "Heartbeat skipped: insufficient credits" |
| failed | "Heartbeat failed: <error>" |

Each event records `wakeup_run_id`, `wakeup_stage`, and `source` in
metadata so the UI can link back to the underlying `AgentRun`.

## InboxEventPlugin

A Jido Plugin on `ConversationAgent` that handles two
responsibilities:

1. **Mention detection**: detects @mentions, creates inbox events,
   enqueues an `AgentRun` with `source: :mention` via
   `RunOrchestrator`.
2. **Approval response detection**: matches button-click responses
   against waiting approval events and resolves them.

**CRITICAL**: This plugin MUST run before `InboundPlugin` in the
plugin list. `InboundPlugin` transforms `message.user` →
`ai.react.query`. If `InboxEventPlugin` runs after, it never sees
`message.user` signals.

```elixir
# In conversation_agent.ex; ORDER MATTERS
plugins: [
  InboxEventPlugin,    # Must see message.user BEFORE InboundPlugin transforms it
  InboundPlugin,       # Transforms message.user → ai.react.query
  StreamingPlugin,
  # ...
]
```

### Approval response detection (v1)

v1 uses text matching on button-click payloads. When the user
clicks "Approve" on an approval card, the button sends
`"Approve: <prompt>"`. The plugin matches
`String.starts_with?(text, "Approve:")` against pending approval
events.

**Limitation**: only reliable for button clicks. Free-text
responses ("yes", "go ahead") will not match. v2 should use the
ConversationAgent's reasoning to detect approval responses from
natural language.

### Key file

- `lib/magus/agents/plugins/inbox_event_plugin.ex`

## Task assignment → inbox events

An Ash change module (`NotifyAgentAssignment`) on `Plan.Task` fires
on create and update:

- **New assignment**: creates `:task_assigned` inbox event. The
  next heartbeat picks it up and the agent decides what to do.
- **Reassignment** (A → B): dismisses old event, creates new event.
- **Unassignment** (A → nil): dismisses old event (cleanup).

Inbox event creation happens in `after_action` (inside the
transaction). No triage dispatch is needed: the event sits in the
inbox until the next heartbeat or @mention wakes the agent.

### Key file

- `lib/magus/plan/task/changes/notify_agent_assignment.ex`

## RequestApproval → inbox events

When an agent calls `RequestApproval`, it creates a `:waiting`
inbox event (via `create_waiting` action). The event appears in the
control room as "Approval needed: ..." with the waiting status.

When the user responds (clicks button), `InboxEventPlugin` detects
and resolves the event.

### Key file

- `lib/magus/agents/tools/tasks/request_approval.ex`

## Multi-agent orchestration

Agents can delegate work to other agents via task assignment. The
system handles the full lifecycle programmatically; no agent
cooperation required.

### Orchestration flow

```
Orchestrator creates tasks with assigned_to_custom_agent_id +
assigned_by_custom_agent_id
         │
         ▼
NotifyAgentAssignment → :task_assigned inbox event on each
assigned agent
         │
         ▼
Next heartbeat (or @mention) wakes the assignee. ConversationAgent
sees the inbox event in its wakeup preamble and decides to act.
         │
         ▼
Agent finishes → AgentRunCompletionPlugin:
  1. Resolves the inbox event (resolved_by: :run_completed)
  2. Updates task: status=:done, result_summary=response text
  3. NotifyTaskCompletion → inbox event on assigning agent
  4. Auto-report → posts result as message in parent conversation
         │
         ▼
Orchestrator sees results appear in their conversation immediately
```

### Key fields

- `Plan.Task.assigned_by_custom_agent_id`: who created/delegated
  the task
- `Plan.Task.assigned_to_custom_agent_id`: who is doing the work
- `Plan.Task.result_summary`: completed work output (set
  automatically from `AgentRun.result_text`)

### Auto-report to parent conversation

When a delegated task completes (`assigned_by != assigned_to`),
`AgentRunCompletionPlugin` automatically posts the result as a
message in the parent conversation (`task.conversation_id`). This
uses the same message creation pattern as `PersistencePlugin`
(`upsert_response` + `Signals.text_complete` + `response_complete`).

The orchestrator does not need to poll or call `ReportToParent`.
Results appear in the conversation as they complete.

### Agent context injection

Every custom agent's wakeup preamble includes an "Available Agents"
section listing sibling agents with their `@handle`, ID, and
description. This gives agents awareness of who they can delegate
to without a tool call.

### Orchestrate skill

The `orchestrate` skill (`priv/skills/orchestrate.md`) teaches
agents the delegation playbook: break down work, confirm plan,
create tasks with assignments, results flow back automatically.

### Key files

- `lib/magus/plan/task/changes/notify_task_completion.ex`: notifies
  parent on task completion
- `lib/magus/agents/plugins/agent_run_completion_plugin.ex`:
  auto-reports results, resolves linked events, advances schedule
- `lib/magus/agents/context/wakeup_preamble.ex`: injects available
  agents and other context into the wakeup preamble
- `priv/skills/orchestrate.md`: orchestration skill

## Cross-layer linkage

### AgentRun ↔ InboxEvent ↔ Plan.Task

```
Plan.Task.assigned_to_custom_agent_id → CustomAgent (worker)
Plan.Task.assigned_by_custom_agent_id → CustomAgent (orchestrator)
AgentRun.task_id → Plan.Task
AgentInboxEvent.agent_run_id → AgentRun (set when run claims event)
```

### Lifecycle

1. Event created (`:pending` or `:waiting`).
2. Heartbeat or @mention enqueues an `AgentRun`. If the run will
   address specific events, they are linked via `agent_run_id` and
   the event status flips to `:processing`.
3. `AgentRun` completes. `AgentRunCompletionPlugin`:
   - Resolves linked inbox events with
     `resolved_by: :run_completed`.
   - Creates an activity log entry.
   - Updates any associated task with `result_summary`.
   - For delegated tasks, posts result to parent conversation and
     notifies the assigning agent.
   - For `:heartbeat` runs, advances `next_scheduled_at` if
     `set_next_wakeup` was not called.
4. If the run fails, linked events are unlinked (`agent_run_id`
   cleared, status reverts to `:pending`) so the next heartbeat
   reconsiders them.

## PubSub broadcasting

| Topic | Consumer |
|-------|----------|
| `agent_activity:user:{user_id}` | Control room (all agents) |
| `agent_activity:{agent_id}` | Agent detail view |
| `agents:{conversation_id}` | Chat UI (message streaming) |

Events: `activity.new`, `activity.inbox_changed`,
`activity.status_changed`, plus the standard
`text.chunk` / `tool.start` / `tool.complete` /
`response.complete` signals from the ConversationAgent's plugins.

### Key file

- `lib/magus/agents/activity_broadcaster.ex`

## Control room UI

### Routes

| Route | LiveView | Purpose |
|-------|----------|---------|
| `/agents` | `AgentsOverviewLive` | Control room: all agents |
| `/agents/:id` | `AgentDetailLive` | Agent detail: drill-down |
| `/agents/new` | `AgentFormLive` | Create new agent |
| `/agents/:id/edit` | `AgentFormLive` | Edit agent |

### Agent detail tabs

1. **Activity**: agent-specific activity log (stream)
2. **Inbox**: pending/waiting/resolved events with dismiss action
3. **Tasks**: assigned `Plan.Task`s grouped by status
4. **Settings**: agent configuration summary with edit link, plus
   a "Run now" button that issues a `:manual_trigger` run.

### Key files

- `lib/magus_web/live/agents_overview_live.ex`
- `lib/magus_web/live/agent_detail_live.ex`
- `lib/magus_web/live/agents_live/agent_helpers.ex`: shared display
  helpers

## Domain organization

All agent resources live in the `Magus.Agents` domain:

| Resource | Purpose |
|----------|---------|
| `CustomAgent` | Agent identity, configuration, schedule fields |
| `AgentSecret` | Encrypted per-agent credentials |
| `AgentInboxEvent` | Universal inbox (awareness layer) |
| `AgentActivityLog` | Audit trail (observability layer) |
| `AgentRun` | Execution tracking (kind, source, status) |
| `AgentState` | Agent process state persistence |

Cross-domain FKs:

- `Plan.Task.assigned_to_custom_agent_id → CustomAgent`
- `AgentRun.task_id → Plan.Task`
- `AgentInboxEvent.agent_run_id → AgentRun`

All modules live under the `Magus.Agents` namespace. Domain
function calls go through `Magus.Agents` directly.

## Key modules

| Module | Purpose |
|---|---|
| `Magus.Agents.Workers.HeartbeatScheduler` | Oban cron poller; per-agent due check + enqueue |
| `Magus.Agents.RunOrchestrator` | Single enqueue gate + budget enforcement |
| `Magus.Agents.AgentRun` | Run record (`kind`, `source`, `status`, etc.) |
| `Magus.Agents.HeartbeatEventMessage` | Visible event message helper |
| `Magus.Agents.Context.WakeupPreamble` | Synthesized system-prompt preamble |
| `Magus.Agents.Plugins.AgentRunCompletionPlugin` | Post-completion event resolution + schedule advance |
| `Magus.Agents.Plugins.InboxEventPlugin` | @mention detection + approval response matching |
| `Magus.Agents.Tools.Autonomy.ListInboxEvents` | Tool: list pending events |
| `Magus.Agents.Tools.Autonomy.DismissEvent` | Tool: resolve event without follow-up |
| `Magus.Agents.Tools.Autonomy.SetNextWakeup` | Tool: override `next_scheduled_at` |
| `Magus.Agents.Strategies.React.TokenAccumulator` | Pure helper for `max_tokens_per_run` (runner integration follow-up) |
