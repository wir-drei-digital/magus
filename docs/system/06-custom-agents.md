# Custom Agents

How users create specialized AI agents with persistent configuration, and how those agents are activated via @mentions, delegated tasks, and the multi-agent orchestration system.

## Overview

A Custom Agent is a user-defined AI persona that bundles instructions, model selection, tool scoping, skills, secrets, and conversation starters into a reusable configuration. Each user has one default agent that powers regular conversations, plus any number of specialized agents.

## Architecture

```
User creates CustomAgent (name, handle, instructions, model, tools, skills, secrets)
    |
    v
User writes "@handle do something" in any conversation
    |
    v
InboxEventPlugin (on ConversationAgent) detects @mentions:
    +---> MentionParser extracts @mentions from message text
    +---> Creates AgentInboxEvent (type: :mention) for observability
    +---> Dispatches DIRECTLY to RunOrchestrator
    +---> Creates AgentRun record (kind: :consult)
    |
    v
RunOrchestrator claims run (advisory locks + SKIP LOCKED)
    |
    v
Agent's home conversation receives the objective as a message
    |
    v
ConversationAgent activates with CustomAgent's config:
    - instructions as system prompt
    - pinned model (or auto-route)
    - tool set filtered by disabled_tool_categories
    - pre-loaded skills
    - agent-scope memory
    |
    v
Agent executes (ReAct loop with tools)
    |
    v
AgentRunCompletionPlugin:
    +---> Marks AgentRun as :complete
    +---> Persists result to source conversation
    +---> Broadcasts run.completed to source PubSub topic
```

## CustomAgent Resource

**File:** `lib/magus/agents/custom_agent.ex`

### Configuration Fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `name` | string | required | Display name |
| `handle` | string | auto-generated | Unique @mention handle (lowercase alphanumeric + hyphens) |
| `description` | string | nil | What this agent does |
| `icon` | string | nil | Emoji or icon identifier |
| `image_path` | string | nil | AI-generated profile image |
| `instructions` | string | nil | System prompt — the agent's persona, behavior, and task-specific guidance |
| `slash_commands` | array of SlashCommand | [] | Custom slash commands shown as conversation starters |
| `chat_mode` | atom | nil | Default mode preset (:chat, :search, :reasoning, etc.) |
| `disabled_tool_categories` | array of atom | [] | Tool categories to disable (:web, :code, :memory, :files, :skills, :tasks, :integrations) |
| `pre_loaded_skills` | array of string | [] | Skill names from registry loaded for every conversation |
| `sampling_settings` | map | nil | LLM settings: temperature, max_tokens, top_p, top_k |
| `max_iterations` | integer | 10 | ReAct loop iterations (1 = single-shot, 20 = max) |
| `is_default` | boolean | false | One per user — powers regular conversations |
| `is_public` | boolean | false | Visible to other users (future) |

### Isolation & Permissions

| Field | Default | Purpose |
|-------|---------|---------|
| `can_read_global_memories` | true | Access user's global (scope: :user) memories |
| `can_write_global_memories` | true | Create/modify global memories |
| `can_access_global_files` | true | RAG search includes user's global files |
| `can_access_knowledge` | true | Access knowledge collection files |

### Autonomy Fields

| Field | Default | Purpose |
|-------|---------|---------|
| `is_paused` | false | Kill switch: stops all heartbeats and blocks @mention dispatch |
| `heartbeat_enabled` | false | Whether the agent receives periodic autonomous wake-ups via the HeartbeatScheduler |
| `heartbeat_instructions` | nil | Custom instructions appended to the agent's system prompt during autonomous wake-ups (used as the `AgentRun.objective`) |
| `heartbeat_default_interval_minutes` | 360 | Fallback cadence between wake-ups when `set_next_wakeup` is not called |
| `max_daily_runs` | nil | Limit on daily AgentRun executions (heartbeat budget gate) |
| `max_tokens_per_run` | nil | Token budget per execution |

### Relationships

- `belongs_to :user` — owner
- `belongs_to :model` — pinned chat model (nil = user default or auto-route)
- `belongs_to :image_model` — pinned image model
- `belongs_to :video_model` — pinned video model
- `belongs_to :workspace` — optional workspace for team agents
- `has_many :conversations` — all conversations using this agent
- `has_many :integrations` — integration configurations (Telegram, webhooks, etc.)
- `has_many :memories` — agent-scope memories (working memory)
- `has_many :secrets` — encrypted secrets (AgentSecret)

### Identities

- `unique_default`: partial unique on `user_id` where `is_default = true` — one default per user
- `unique_handle_per_user`: unique on `[:handle, :user_id]` — handles unique within a user's agents

## @Mention System

### MentionParser

**File:** `lib/magus/agents/support/mention_parser.ex`

- Regex: `~r/(?:^|(?<=\s))@([a-z0-9][a-z0-9-]*)` — matches handles after whitespace, not in email addresses
- Max 3 mentions per message (deduplicated)
- Resolves handles to CustomAgent records owned by the message author
- Silently ignores unknown handles
- `strip_mentions/2` removes resolved @tokens from message text

### Mention Dispatch

Mention dispatch is handled directly by `InboxEventPlugin` (not a separate module). When the plugin detects @mentions in a `message.user` signal:

1. Creates `AgentInboxEvent` (type: `:mention`, urgency: `:immediate`) for control room visibility
2. Finds/creates home conversation via `HomeConversation.ensure/2` (advisory lock to prevent races)
3. Creates `AgentRun` (kind: `:consult`) with idempotency key
4. Enqueues via `RunOrchestrator`
5. Returns `{:ok, :continue}` — the conversation flow continues normally

**File:** `lib/magus/agents/plugins/inbox_event_plugin.ex`

## Multi-Agent Orchestration

### AgentRun

**File:** `lib/magus/agents/agent_run.ex`

Tracks sub-agent task execution:

| Field | Type | Purpose |
|-------|------|---------|
| `kind` | atom | `:consult`, `:delegate`, `:subtask` |
| `status` | atom | `:pending` → `:running` → `:complete` / `:error` / `:timed_out` / `:cancelled` |
| `source_conversation_id` | uuid | Parent conversation |
| `target_conversation_id` | uuid | Child conversation doing the work |
| `target_agent_id` | uuid | FK to CustomAgent |
| `objective` | string | What the agent should do |
| `result_text` | string | Agent's result (on completion) |
| `error_message` | string | Error details (on failure) |
| `last_heartbeat_at` | datetime | Liveness tracking |
| `idempotency_key` | string | Prevents duplicate runs |

### RunOrchestrator

**File:** `lib/magus/agents/run_orchestrator.ex`

Distributed-safe work queue:
- `pg_advisory_xact_lock(hashtext($1), 0)` per target conversation
- `FOR UPDATE SKIP LOCKED` for non-blocking concurrent claiming
- `max_parallel_runs_per_target` (default: 3)
- Public functions: `enqueue/1`, `maybe_start_next/1`
- Run completion handled via Ash actions: `Magus.Agents.complete_agent_run/2`, `Magus.Agents.fail_agent_run/2`

### SpawnSubAgent Tool

**File:** `lib/magus/agents/tools/tasks/spawn_sub_agent.ex`

Two dispatch modes:
1. **Custom agent mode** (`custom_agent_id`): Inherits the agent's config
2. **Inline mode** (`model_key` + `system_prompt`): One-off with explicit config

Max 3 concurrent sub-agents per conversation. Returns immediately with `task_id` and `child_conversation_id`.

### AwaitSubAgents Tool

**File:** `lib/magus/agents/tools/tasks/await_sub_agents.ex`

Polls AgentRun records every 2s. Modes: `"all"` (wait for all) or `"any"` (first to complete). Configurable timeout (default: 300s). Heartbeats pending runs to prevent stale cleanup.

## Tool Resolution

**File:** `lib/magus/agents/tools/tool_builder.ex`

Tools are resolved per-conversation based on CustomAgent config:

```
Tier 1: Base tools (LoadSkill, WebFetch, Rag, DiceRoll, memory, multi-agent)
    |
Tier 2: Mode-specific (WebSearch for :search mode)
    |
Tier 3: Task conversation structural (ReportToParent, CompleteTask)
    |
Tier 4: Skill-gated (unlocked by loaded skills)
    |
Tier 5: Integration tools (per agent's enabled integrations)
    |
Tier 6: Pre-loaded skills (from agent.pre_loaded_skills)
    |
    v
Filter by agent.disabled_tool_categories
    |
    v
Final tool set passed to ReactStrategy
```

**Categories:** `:web`, `:code`, `:memory`, `:files`, `:skills`, `:tasks`, `:integrations`

Sub-agent conversations get a reduced tool set: no `SpawnSubAgent`/`AwaitSubAgents` (prevents recursive spawning).

## Model Resolution

**File:** `lib/magus/agents/routing/model_key_resolver.ex`

Four-level priority cascade (applied independently for chat, image, video):

1. Conversation-selected model
2. CustomAgent pinned model
3. User's default model
4. `:auto` (chat only — triggers AutoRouter) or system default

## Agent-Scope Memory

Agents have their own memory scope (`:agent`) for persistent working state:

```elixir
# Memory scoped to this custom agent
Magus.Memory.create_agent_memory(%{
  custom_agent_id: agent.id,
  name: "task:sentry-check",
  content: "Last checked: 2026-03-15. Processed IDs: [123, 456]."
}, actor: ai_actor())
```

- Full CRUD parity: `create_agent`, `agent_by_name`, `for_agent`, `semantic_search_agent`
- Unique per `(custom_agent_id, name)` — updating by name overwrites
- Persists across conversations and heartbeats
- Used for: task state, processed item tracking, pending approvals

## Agent Secrets

**File:** `lib/magus/agents/agent_secret.ex`

Per-agent encrypted secrets (AES-256-GCM via Cloak vault). See [Sandbox Execution](./10-sandbox-execution.md) for injection details.

- `key`: env var name (validated: `^[A-Za-z_][A-Za-z0-9_]*$`)
- `value`: encrypted at rest, never in LLM context
- `scope`: `:sandbox_env` (injected as `/workspace/.env`) or `:tool_config`
- Cascade delete: deleting the agent deletes its secrets
- Identity: unique per `(custom_agent_id, key)`

## Skills Integration

**File:** `priv/skills/*.md`

Skills are markdown instruction sets loaded at runtime:

- `pre_loaded_skills` on CustomAgent: loaded automatically for every conversation
- `LoadSkill` tool: agent can dynamically load skills during execution
- `slash_commands` on CustomAgent: user-facing shortcuts that inject instructions

Example: A dev agent with `pre_loaded_skills: ["dev_agent"]` gets sandbox code work instructions automatically. The `/council` slash command loads the council skill for multi-perspective review.

## Autonomous Wake-ups

Agents act proactively via the `HeartbeatScheduler` Oban cron worker. The scheduler enqueues an `AgentRun` (source: `:heartbeat`) through `RunOrchestrator` for every agent whose `heartbeat_enabled` is true and whose `next_scheduled_at` has elapsed.

```
HeartbeatScheduler (every 5 min) → RunOrchestrator.enqueue (source: :heartbeat)
  → ConversationAgent in home conversation runs its normal ReAct loop
  → Builder prepends a WakeupPreamble (current time, inbox stats, open
    tasks, recent activity, autonomy tool hints)
  → Agent uses normal tools plus four autonomy-only tools:
      list_inbox_events, dismiss_event, link_inbox_event, set_next_wakeup
  → AgentRunCompletionPlugin resolves linked inbox events on success and
    advances next_scheduled_at if set_next_wakeup was not called
```

The agent controls its own schedule by calling `set_next_wakeup` during a run, otherwise the fallback cadence in `heartbeat_default_interval_minutes` applies. See [Agent Control Plane](./07-agent-control-plane.md) for the full run-plane and budget details.

## Domain Interfaces

```elixir
# List user's agents
Magus.Agents.list_my_agents(actor: user)

# Create an agent
Magus.Agents.create_custom_agent(%{
  name: "Dev Agent",
  instructions: "You are a development assistant. Clone https://github.com/org/repo ...",
  pre_loaded_skills: ["dev_agent"],
  disabled_tool_categories: [],
  max_iterations: 15
}, actor: user)

# Update
Magus.Agents.update_custom_agent(agent, %{instructions: "..."}, actor: user)

# Manage secrets
Magus.Agents.create_agent_secret(%{
  custom_agent_id: agent.id,
  key: "GITHUB_TOKEN",
  value: "ghp_abc123",
  scope: :sandbox_env
}, actor: user)
```
