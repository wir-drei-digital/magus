# Plan Domain: Collaborative Task Management

A shared task list where users and AI agents can create, update, and complete tasks collaboratively in real-time.

## Philosophy

Simple primitive — a shared mutable list — that enables complex workflows. The agent and user coordinate through a visible, interactive task list. Both sides can create, check off, edit, reorder, and remove tasks at any time.

## Architecture Overview

```
Agent creates tasks via tools ──┐
                                v
                         Magus.Plan.Task (Ash resource)
                                |
                         BroadcastTaskEvent change
                                |
                    ┌───────────┴───────────┐
                    v                       v
             PubSub broadcast        System prompt injection
             (UI real-time)          (agent awareness per turn)
                    |                       |
                    v                       v
          TaskPaneComponent          TaskContext.build/1
          (inside chat-input-card)   (markdown checklist with IDs)
                    |
                    v
           User clicks checkbox,
           edits title, drags to reorder,
           adds tasks, removes tasks
                    |
                    v
             TaskHandlers ──> Ash actions ──> PubSub broadcast (loop)
```

## Domain: `Magus.Plan`

**File:** `lib/magus/plan.ex`

### Task Resource (`Magus.Plan.Task`)

**File:** `lib/magus/plan/task.ex`
**Table:** `plan_tasks`

| Field | Type | Notes |
|-------|------|-------|
| `id` | uuid_v7 | Primary key |
| `title` | string | Required |
| `description` | string | Optional |
| `status` | atom | `:open`, `:in_progress`, `:done`, `:cancelled`, `:archived`, `:blocked` |
| `position` | integer | Auto-incremented within scope |
| `conversation_id` | FK | Required, on_delete: :delete |
| `parent_id` | FK (self) | Nullable, single-level nesting only |
| `assigned_to_user_id` | FK (User) | Nullable |
| `assigned_to_agent` | string | Default: `"assistant"` |
| `assigned_to_custom_agent_id` | FK (CustomAgent) | Agent assigned to do the work |
| `assigned_by_custom_agent_id` | FK (CustomAgent) | Agent that delegated the task |
| `completed_by` | string | Auto-set: `"user"` or `"agent"` on status → `:done` |
| `result_summary` | string | Completed work output (set from AgentRun result_text) |
| `blocked_reason` | string | Why this task is blocked |
| `waiting_on_user` | boolean | Whether task is waiting for human input (default false) |
| `due_at` | utc_datetime_usec | Optional deadline for the task |
| `recurrence` | map | Optional recurrence pattern (e.g., `%{frequency: :daily, interval: 1}`) |
| `metadata` | map | Flexible storage |

**Nesting:** Tasks support one level of subtasks. A task with `parent_id` set is a subtask. Subtasks cannot have children (enforced by `ValidateNesting` change).

**Ordering:** Position auto-increments within scope (same `parent_id` + `conversation_id`). Ties broken by `inserted_at`.

**Assignment:** Default is `@agent`. When assigned to user, `assigned_to_agent` is cleared (mutual exclusivity). Priority: `assigned_to_user_id` > `assigned_to_agent` for display.

### Custom Changes

| Change | File | Purpose |
|--------|------|---------|
| `ValidateNesting` | `task/changes/validate_nesting.ex` | Ensures parent has no parent (single-level) |
| `AutoPosition` | `task/changes/auto_position.ex` | Sets position to max+1 in scope |
| `SetCompletedBy` | `task/changes/set_completed_by.ex` | Auto-sets `completed_by` based on actor type |
| `BroadcastTaskEvent` | `task/changes/broadcast_task_event.ex` | PubSub broadcast after create/update |
| `NotifyAgentAssignment` | `task/changes/notify_agent_assignment.ex` | Creates an inbox event for the assigned agent. The agent picks it up on its next heartbeat wake-up. |
| `NotifyTaskCompletion` | `task/changes/notify_task_completion.ex` | Notifies assigning agent when task completes |
| `SpawnRecurrence` | `task/changes/spawn_recurrence.ex` | On status -> :done with recurrence + due_at, spawns next occurrence with shifted due date. Timezone-aware (uses assigned user's timezone). |

### TaskPaneState Resource

**File:** `lib/magus/plan/task_pane_state.ex`
**Table:** `plan_task_pane_states`

Per-user per-conversation pane visibility tracking with upsert dismiss/reopen actions. Identity on `[:conversation_id, :user_id]`.

## AI Tools

Four tools, all registered in `ToolBuilder` with category `:plan` and included in `main_tools`.

### `create_task`

**File:** `lib/magus/agents/tools/plan/create_task.ex`

Creates one or more tasks. Supports batch creation via `tasks` array for preserved ordering. Accepts optional `due_at` (ISO8601 string) and `recurrence` (map with frequency/interval).

**Single task:**
```
create_task(title: "Write intro", assigned_to: "user", due_at: "2026-04-05T09:00:00Z")
```

**Recurring task:**
```
create_task(title: "Daily practice", assigned_to: "user", due_at: "2026-04-01T09:00:00Z", recurrence: %{frequency: "daily", interval: 1})
```

**Batch (ordered):**
```
create_task(tasks: [
  %{title: "Research", assigned_to: "agent"},
  %{title: "Outline", assigned_to: "agent"},
  %{title: "Review", assigned_to: "user", due_at: "2026-04-05T09:00:00Z"}
])
```

### `update_task`

**File:** `lib/magus/agents/tools/plan/update_task.ex`

Updates any field on a task. Scoped to conversation (can't update tasks in other conversations). Status string → atom conversion handled automatically. Accepts optional `due_at` and `recurrence`.

### `list_tasks`

**File:** `lib/magus/agents/tools/plan/list_tasks.ex`

Returns all non-archived tasks grouped by parent with subtasks nested.

### `clear_tasks`

**File:** `lib/magus/agents/tools/plan/clear_tasks.ex`

Archives all `:done` tasks in the conversation. Archived tasks are excluded from queries, context, and UI but preserved in the database.

## Agent Awareness

### System Prompt Injection

**File:** `lib/magus/agents/context/task_context.ex`

Each turn, the system prompt builder queries non-archived tasks and renders a markdown checklist with IDs:

```markdown
## Tasks

- [ ] Research competitors (@agent) [id:019cf8a1-...]
  - [x] Check pricing (completed by agent) [id:019cf8a2-...]
  - [ ] Review features [id:019cf8a3-...]
- [ ] Write draft (@user) [id:019cf8a4-...]

Use `create_task` to add tasks, `update_task` to change status/assignment,
`list_tasks` to see full details with IDs.
```

IDs are included so the agent can call `update_task` without needing to `list_tasks` first.

### System Prompt Guidance

The base system prompt (`system_prompts.ex`) includes behavioral guidance:

- Create tasks for multi-step work, not one-shot requests
- Use batch creation (`tasks` array) to preserve ordering
- Assign `"user"` for human tasks, default `@agent` for AI tasks
- Use `clear_tasks` to archive when a batch is complete

### Wiring

**Builder:** `lib/magus/agents/context/builder.ex` — runs `TaskContext.build/1` in parallel with workspace/jobs/draft/memory context queries.

**SystemPrompts:** `lib/magus/agents/context/system_prompts.ex` — `tasks_context` passed through to compose, placed between `jobs_context` and `skill_context`.

## UI: Task Pane Component

**File:** `lib/magus_web/live/chat_live/components/tasks/task_pane_component.ex`

Rendered inside the `chat-input-card` div (same glassmorphism container as the textarea), above the message input. Not a side pane — coexists with draft/pdf panes.

### Layout

```
┌─────────────────────────────────────────────┐
│ > ☑ Tasks  2/5               ● ● ● ● ●     │  Collapsed (default)
├─────────────────────────────────────────────┤
│ v ☑ Tasks  2/5               ● ● ● ● ●     │  Expanded header
│ ⠿  ☐  Research           @agent        ✕   │  Task row
│    ⠿  ☐  Check pricing   @agent        ✕   │  Subtask (indented)
│ ⠿  ☑  Write draft        @you              │  Done task (no undo)
│ + Add task                                   │
├─────────────────────────────────────────────┤  Border (expanded only)
│ [  Type a message...                    ⏎ ] │  Chat input
└─────────────────────────────────────────────┘
```

### User Interactions

| Interaction | Behavior |
|-------------|----------|
| Click collapse header | Toggle expanded/collapsed |
| Click checkbox (open task) | Mark as done (irreversible from UI). Triggers recurrence if applicable. |
| Click task title | Inline edit (not available for done tasks) |
| Drag handle (⠿) | Reorder via Sortable.js |
| `+` button on task row | Add subtask (hover-visible) |
| `✕` button on task row | Remove/destroy task (hover-visible) |
| `+ Add task` | Inline form with assignee dropdown |
| Assignee dropdown | Select @agent (default) or @you |

### Due Dates

Tasks with a `due_at` value show a compact due date label after the title. Uses shared `DueDateHelpers` module for formatting. Overdue tasks display in red (`text-error`).

### New Chat Page

When no conversation is selected, the new chat page shows up to 10 open tasks assigned to the current user (via `open_for_user` action), sorted by due date. Each task links to its conversation. Uses the same `DueDateHelpers` for overdue formatting.

### Collapsed State

Shows a single-line header with:
- Chevron (expand/collapse indicator)
- Check-square icon
- "Tasks" label
- Done/total count (e.g., "2/5")
- Progress dots (green = done, blue = in_progress, gray = open)

### Sortable.js Integration

Colocated hook `.TaskSortable` using `window.Sortable` (exposed from `app.js`). Drag handle uses `.task-handle` CSS class. Two sortable containers:

1. `#top-level-tasks` — reorder top-level task groups
2. `#subtasks-{parent_id}` — reorder subtasks within a parent

On drag end, all sibling positions are updated atomically to prevent ordering conflicts.

## PubSub

### Topic

`tasks:conversation:{conversation_id}`

### Events

| Event | Payload | Trigger |
|-------|---------|---------|
| `task.created` | `%{task: task}` | Task created (user or agent) |
| `task.updated` | `%{task: task}` | Task updated (status, title, position, etc.) |

### LiveView Integration

**Subscriptions:** `lib/magus_web/live/chat_live/helpers.ex` — subscribe/unsubscribe alongside drafts topic.

**Handlers:** `lib/magus_web/live/chat_live/task_handlers.ex`

| Handler | Purpose |
|---------|---------|
| `handle_task_created/2` | Add to list (with dedup check), auto-expand if collapsed |
| `handle_task_updated/2` | Replace task in list by ID |
| `handle_toggle_task/2` | Mark open → done (irreversible from UI) |
| `handle_add_task/4` | Create task with title, parent, assignee |
| `handle_update_title/3` | Inline title edit |
| `handle_remove_task/2` | Destroy task |
| `handle_reorder_task/3` | Atomic reorder of all siblings |
| `assign_task_pane/1` | Load tasks for conversation on mount |

### Deduplication

`handle_task_created` checks if the task ID already exists in the local list before appending. This prevents duplicates when the user creates a task from the pane (local append + PubSub broadcast would otherwise double-add).

## Feature Usage Tracking

Track via `create_task` tool execution in `ToolEventPlugin.maybe_track_feature_usage/2`:

```elixir
"create_task" -> Magus.FeatureUsage.track(user_id, "tasks", "create")
```

## File Structure

```
lib/magus/plan.ex                                      # Domain
lib/magus/plan/task.ex                                  # Task resource
lib/magus/plan/task/changes/validate_nesting.ex         # Single-level nesting
lib/magus/plan/task/changes/auto_position.ex            # Auto-increment position
lib/magus/plan/task/changes/set_completed_by.ex         # Actor-based completed_by
lib/magus/plan/task/changes/broadcast_task_event.ex     # PubSub broadcast
lib/magus/plan/task/changes/spawn_recurrence.ex         # Recurring task spawning (timezone-aware)
lib/magus/plan/task_pane_state.ex                       # Per-user pane visibility

lib/magus/agents/tools/plan/create_task.ex              # AI tool (batch support)
lib/magus/agents/tools/plan/update_task.ex              # AI tool
lib/magus/agents/tools/plan/list_tasks.ex               # AI tool
lib/magus/agents/tools/plan/clear_tasks.ex              # AI tool (archive done)

lib/magus/agents/context/task_context.ex                # System prompt injection

lib/magus_web/live/chat_live/task_handlers.ex           # LiveView handlers
lib/magus_web/live/chat_live/components/tasks/
  task_pane_component.ex                                 # UI component
  due_date_helpers.ex                                    # Shared due date formatting

test/magus/plan/task_test.exs                           # Resource tests
test/magus/agents/tools/plan/create_task_test.exs       # Tool tests
test/magus/agents/tools/plan/update_task_test.exs
test/magus/agents/tools/plan/list_tasks_test.exs
test/magus/agents/context/task_context_test.exs         # Context tests
```

## Future Extensions

- **Board resource** (`Magus.Plan.Board`) — group tasks across conversations, workspace-scoped
- **Multi-agent assignment** — custom agents pick up tasks via heartbeat check-ins
- **Stuck task detection** — heartbeat notices tasks reopened repeatedly, suggests breakdown
- **Kanban view** — board-level UI with column layout by status
