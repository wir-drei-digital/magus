# CLAUDE.md

Magus is a Phoenix/LiveView app: AI chat with agentic tool execution, prompt library, subscriptions. Stack: Ash 3.x + AshPostgres, Jido agents, ReqLLM, pgvector, MDEx, Tailwind 4 + DaisyUI.

## Commands

```bash
mix setup                    # deps + migrations + assets
mix phx.server               # or `iex -S mix phx.server`

# Database — NEVER run `mix ash.reset` (wipes all data). Use new migrations or direct SQL.
mix ash.setup                # Create DB + run migrations
mix ash.codegen              # Generate migrations after schema changes
mix ash.migrate              # Run migrations only

# Tests
mix test                                    # All non-live tests
mix test path/to/file.exs[:LINE]            # Single file/line
bin/test-e2e-live                           # Live E2E (loads .env, excludes :sandbox)
bin/test-e2e-live --include sandbox         # Include sandbox-requiring tests

# Quality
mix precommit                # compile --warnings-as-errors, deps.unlock --unused, format, test --exclude e2e

# Assets
mix assets.build / mix assets.deploy
```

Dev routes (dev env): `/dev/dashboard`, `/dev/mailbox`, `/oban`, `/admin`, `/api/json/swaggerui`.

## Ash Domains (`config/config.exs`)

- **Accounts** — User (password + magic link via AshAuthentication), settings, model selection
- **Chat** — Conversation, Message, Model, MessageUsage, Folder, ConversationMember, ConversationInviteLink, ConversationInvitation, ConversationShareLink, ConversationFavorite, ConversationCompanion, RoutingSlot, PaneState, UserFolderState
- **Library** — Prompt, Tag, Favorite, Example (pgvector semantic search)
- **Files** — File, Chunk (pgvector)
- **Memory** — Memory (scope: local/user/agent), MemoryVersion, MemorySource, MemoryAssociation (Hebbian edges)
- **Subscriptions** — UsagePlan, UserSubscription, UserUsageOverride; enforced by `LimitEnforcer`
- **Agents** — CustomAgent, AgentSecret, AgentState, AgentRun, AgentInboxEvent, AgentActivityLog
- **Plan** — Task, TaskPaneState (collaborative tasks between users + agents)
- **Drafts** — draft message storage
- **Notifications** — user-facing notifications
- **Sandbox** — sandboxed code execution
- **Integrations** — external services
- **Workflows** — workflow definitions
- **Workspaces** — Workspace, WorkspaceMember, ResourceAccess (shared access-grant model; see below)
- **Brain** — BrainResource, Page (markdown `body` + YAML `frontmatter`; single write path `update_body` with `lock_version` optimistic lock; per-page AshPaperTrail versions), PageLink (`[[wikilink]]` backlink index, rebuilt on save), PageChunk + Source + SourceChunk (pgvector search over pages and ingested sources), PageTag (frontmatter `tags:` + `#tag`). Markdown-as-storage: links are authored in-text as `[[Page Name]]`; `Block`/`Connection` are removed and typed relationships (`supports`/`contradicts`/`derived_from`) live in the Super Brain. Arbitrary page nesting.
- **Knowledge** — KnowledgeSource, KnowledgeCollection
- **Workbench** — TabSession (workbench shell state)
- **FeatureUsage** — FeatureUsageEvent, Announcement (onboarding/discovery tracking)

## Jido Agent Architecture

Each conversation has a `ConversationAgent` (id `conv:<uuid>`) managed by `Jido.Agent.InstanceManager`. Uses `ReactStrategy` for the ReAct loop and composable plugins to translate strategy signals into PubSub + DB writes. Agents hibernate to Postgres after 5 min idle (`:agent_idle_timeout` config) and thaw on next message. Mid-turn hibernation is detected by `Magus.Agents.Recovery` (via `__recovery__` key) and the turn is retried; streaming messages stuck in `:streaming` get cleaned up.

```
User message → Magus.Chat.Message.Changes.SignalAgent → InstanceManager.get/start
              ↓
      InboxEventPlugin sees raw message.user (mention/approval matching)
              ↓
      InboundPlugin: message.user → ai.react.query (+ pre-flight validation)
              ↓
      ReactStrategy spawns ReAct worker
              ↓
      Worker: LLM call → tool exec → loop
              ↓
      Plugins translate internal signals:
        Streaming  → text.chunk / thinking.chunk
        Persistence → DB write + text.complete
        ToolEvent  → tool.start / tool.complete (+persist)
        Usage      → MessageUsage row
        AgentRunCompletion → AgentRun status + run.completed/failed
              ↓
      Persistence broadcasts response.complete → idle (hibernate after 5 min)
```

### Plugins (`lib/magus/agents/plugins/`)

Order matters: **InboxEventPlugin MUST run before InboundPlugin** — Inbound transforms `message.user` → `ai.react.query`, so InboxEvent needs to see the raw `message.user` first.

| Plugin | Purpose |
|---|---|
| InboxEventPlugin | @mention detection + approval matching (must be first) |
| InboundPlugin | `message.user` → `ai.react.query` + pre-flight validation |
| StreamingPlugin | LLM streaming → `text.chunk` / `thinking.chunk` PubSub |
| PersistencePlugin | Persists agent message; broadcasts `text.complete` / `response.complete` |
| ToolEventPlugin | Persists tool result; broadcasts `tool.start` / `tool.complete` |
| UsagePlugin | Records token usage to `MessageUsage` |
| AgentRunCompletionPlugin | Marks `AgentRun` complete/failed; resolves linked inbox events |
| IntegrationReplyPlugin | Sends replies to external channels (Telegram, etc.) |
| ActivityLogPlugin | Audit trail for control room |

Shared helpers in `lib/magus/agents/plugins/support/`: Preflight, Persistence, Helpers, MediaBypass.

### Signal types & persistence

| Signal | Source | Persisted? |
|---|---|---|
| `text.chunk` / `thinking.chunk` | Streaming | No (UI only) |
| `turn.started` / `turn.completed` | Streaming | No |
| `text.complete` | Persistence | **Yes** (agent message) |
| `tool.start` | ToolEvent | No |
| `tool.progress` | tool via Signals | No |
| `tool.complete` | ToolEvent | **Yes** (tool event message) |
| `response.complete` / `error` / `state.change` | various | No |
| `run.started` | RunOrchestrator | No |
| `run.progress` | AgentRunCompletion | No |
| `run.completed` / `run.failed` | AgentRunCompletion | **Yes** (AgentRun) |

PubSub topic: `agents:{conversation_id}`. LiveViews subscribe in `mount` (gated by `connected?(socket)`) and route signals through their `PubSubHandlers`.

### Agent state (hibernation-relevant only)

```elixir
%{conversation_id, user_id,
  model_keys: %{chat, image, video},
  mode: :chat | :search | :reasoning | :image_generation | :video_generation}
```

Strategy keeps its own internal state (iteration, accumulated text, pending tool calls) separately. Serialize via `checkpoint/2` / `restore/2` callbacks using `Magus.Agents.Persistence` helpers (`wrap_checkpoint/3`, `extract_state/1`, `get_value/2`). Agent ID convention: `"type:uuid"`.

## Jido Tools (Actions)

Tools live in `lib/magus/agents/tools/<category>/`. Each implements `use Jido.Action`, plus `display_name/0`, `summarize_output/1`, and `run(params, context)`. Register via `ReactStrategy` options on the agent, or dynamically via `ai.react.register_tool` signal.

### Schema gotcha (CRITICAL — silently breaks tools)

For nullable fields you MUST use `{:or, [<type>, nil]}`. NimbleOptions silently rejects `default: nil` with a bare type, the tool's `run/2` is never called, and Jido reports a generic "Instruction failed" with no detail.

```elixir
# WRONG — never reaches run/2 when model is nil
model: [type: :string, default: nil]

# CORRECT
model: [type: {:or, [:string, nil]}, default: nil]
```

Other patterns: `type: {:in, [...]}` for enums, `type: {:list, :string}` for lists. To debug missing-`run/2` issues, add `on_before_validate_params/1` / `on_after_validate_params/1` hooks.

### Tool context & progress

Context passed to `run/2` includes `user_id`, `conversation_id`, plus event metadata `__event_id__`, `__tool_name__`, `__conversation_id__`. Emit progress to the `agents:{conversation_id}` topic:

```elixir
alias Magus.Agents.Signals
Signals.emit_tool_progress(context, :searching, %{query: q})
```

Validate required context keys with `Magus.Agents.Tools.Helpers.validate_context(context, [:user_id, :conversation_id])`.

## Multi-Agent Orchestration

`AgentRun` is the universal unit of agent work; `RunOrchestrator` is the single enqueue gate. Every wakeup flows through the same path — only `source` differs.

| Source | Trigger |
|---|---|
| `:mention` | `InboxEventPlugin` detects @mention |
| `:sub_agent_spawn` | `SpawnSubAgent` tool |
| `:heartbeat` | `HeartbeatScheduler` Oban cron (`*/5 * * * *`) |
| `:manual_trigger` | "Run now" UI |

For `:heartbeat` / `:manual_trigger`, the Builder prepends a `Magus.Agents.Context.WakeupPreamble` (inbox stats, open tasks, recent activity) and adds three autonomy-only tools: `list_inbox_events`, `dismiss_event`, `set_next_wakeup`. The home conversation gets one `:event` trace message per wake-up that transitions `running` → `complete | skipped | failed`.

**AgentRun fields**: `kind` (`:consult | :delegate | :subtask`), `source`, `status` (`:pending → :running → :complete | :error | :timed_out | :cancelled`), `source_conversation_id`, `target_conversation_id`, `request_id`, `idempotency_key`, `heartbeat_at`.

**RunOrchestrator** uses `pg_advisory_xact_lock` + `FOR UPDATE SKIP LOCKED` for distributed-safe claiming. Concurrency capped by `max_parallel_runs_per_target`. Budget gates at `enqueue/1`: `max_daily_runs` (heartbeat), `max_tokens_per_run` (all), subscription credits (heartbeat).

Sub-agent flow: `SpawnSubAgent` creates a child conv + enqueues run; `AwaitSubAgents` polls until terminal; child calls `ReportToParent` to send results back. `AgentRunCompletionPlugin` resolves linked `AgentInboxEvent`s (`agent_run_id == run.id`) as `:run_completed` on success; on failure it clears `agent_run_id` so the next heartbeat reconsiders. Advances `next_scheduled_at` for heartbeats that didn't call `set_next_wakeup`.

## Skills

Markdown files in `priv/skills/` with YAML frontmatter (`name`, `description`, optional `tags`). Loaded by `Magus.Agents.Skills.Registry` GenServer at startup; listed in the system prompt when `load_skills: true`. AI invokes the `load_skill` tool to fetch full content. Hot-reload in dev via `Registry.reload()`.

## Data Model

### Workspace-scoped resources (shared access-grant model)

`Folder`, `File`, `Conversation`, `Prompt`, `CustomAgent`, `Brain`, `KnowledgeCollection` all share this model:

- `user_id` — creator, implicitly `:owner`
- `workspace_id` — nullable (null = personal)
- Extra access via `resource_accesses` rows: `(grantee_type: :user | :workspace | :custom_agent, grantee_id, role)`
- Roles: `:viewer < :editor < :owner`. Workspace `:admin` is implicitly `:owner` on every resource in that workspace.

Wire policies with the shared macro:

```elixir
policies do
  import Magus.Workspaces.Policies
  workspace_scoped_policies(resource_type: :folder)
  # + per-resource extras via :extra_read / :extra_update / :extra_destroy / :extra_create / :owner_expr
end
```

Grant lifecycle goes through the `Magus.Workspaces` domain: `grant_access/2`, `revoke_access/2`, `list_access_for_resource/3`. Key modules: `Magus.Workspaces.ResourceAccess`, `…Policies`, `…AccessCheck` (`has_access?/4` helper), validations `ParentInSameWorkspace` / `FolderInSameWorkspace`, change `DestroyResourceGrants` (after_action cleanup).

Drafts inherit access from their parent conversation; no own `workspace_id` or grants.

### Folder

Shared by Conversations and Files. `kind`: `:files | :conversations | :mixed`. Set at creation based on UI context. Cross-kind content silently promotes via `Magus.Chat.Folder.Changes.PromoteKindForContent` (one-way `:promote_to_mixed` action). Each nav filters by `[<own_kind>, :mixed]`.

### Conversation / Message / Model

- **Conversation** `chat_mode`: `:chat | :search | :reasoning | :image_generation | :video_generation`; `system_prompt_id`, `sampling_settings`, `is_multiplayer`, `visibility`. Oban triggers: `:name_conversation`, `:extract_memories`.
- **Message** `role`: `:system | :user | :agent | :tool`; `message_type`: `:message | :event | :job_trigger`; `status`: `:pending | :streaming | :complete | :error`. Plus `tool_call_data`, `citations`, `reasoning_details`. `SignalAgent` change triggers the agent on user message creation.
- **Model** `api_provider`: `:openrouter | :xai | :publicai | :aimlapi`. Capability flags: `supports_search?`, `supports_reasoning?`, `supports_tools?`. `cost_multiplier`: credit cost per use (1x basic, 3x standard, 10x premium).
- **MessageUsage** per-message token tracking (prompt/completion/reasoning/cached + input/output cost). Never deleted; FKs nilify on message delete.

### Subscriptions

`UsagePlan` (`key`, `daily_credits`, `max_cost_multiplier`, `storage_bytes`, `max_upload_bytes`, Stripe price IDs) → `UserSubscription` (`status: :active | :past_due | :canceled | :trialing`, cached `storage_usage_bytes`). Admin grants via `UserUsageOverride` (optional `expires_at`). Limit checks in `Magus.Subscriptions.LimitEnforcer` before generation; stats from `UsageCalculator`.

## Super Brain (graph layers)

Cross-resource knowledge graph on **FalkorDB** (Redis-protocol graph DB). Three layers; the graph (L1+L2) is a **derived, disposable index over Layer 0**, never the source of truth.

- **Layer 0** (canonical resources, Postgres = source of truth): brain pages/sources, memories, files/chunks, drafts, messages. `SuperBrain.GraphRouter.graph_for/2` maps each resource to a graph name.
- **Layer 1** (per-resource source graphs, FalkorDB): `brain:<id>`, `memories:user|workspace:<id>`, `files:user|workspace:<id>`, `drafts:user:<id>`. Built by `SuperBrain.Workers.Extract*` via LLM extraction into `(:Episode)-[:HAS_ENTITY]->(:Entity)-[:RELATES_TO]->(:Entity)`.
- **Layer 2** (per-accessor super graph, FalkorDB): `super:user:<id>`, `super:workspace:<ws>:<id>`; canonical entities fused across L1 (deterministic name-hash `CanonicalId`, no LLM/embedding merge yet). Retrieval entry point: `SuperBrain.Retrieval`, `super_brain_search` tool.

**Rebuildable, no data loss**: graph-identity changes are NOT Postgres migrations. Bump `entity_version`/`canonical_version` in `SuperBrain.Migration`; nodes carry a `migration_marker`; `MigrationSweeper` rebuilds stale graphs from Layer 0 (L2 replays cheaply, L1 re-extracts). To improve the graph model: bump the marker and rebuild. Key modules: `lib/magus/super_brain/{graph_router,super_graph,canonical_id,retrieval,migration}.ex`.

## Ash conventions

- Call resources through code interfaces on domains (`MyDomain.get_thing!/2`), not `Ash.read/4` directly
- Custom changes in `lib/magus/<domain>/<resource>/changes/` (prefer over anonymous `change fn`)
- Calculations in `lib/magus/<domain>/<resource>/calculations/`
- `require Ash.Query` before using `Ash.Query.filter/2` (it's a macro)
- Lifecycle: `before_action` / `after_action` for in-transaction logic; `before_transaction` / `after_transaction` for outside
- **Authorization**: pass `actor:` (a real user). Don't reach for `authorize?: false` in app code.
- **Actor in expressions**: use `actor(:id)` in filter `expr/1` when callers always have a user as actor. Keep explicit `user_id` arg ONLY for actions also called from AI tools where `ai_actor()` is used (no user id).

## Phoenix LiveView conventions

- **Collections** always use streams (`stream/3`, `stream_insert/3`, `stream_delete/3`). Templates: `phx-update="stream"` consuming `@streams`. Streams are NOT enumerable — to refresh, refetch + `stream(..., reset: true)`.
- **Forms**: `to_form/2` + `<.form for={@form}>` + `<.input field={@form[:field]} />`
- **Navigation**: `<.link navigate={…}>` / `push_navigate/2` (NOT deprecated `live_redirect`)
- **Inline scripts**: colocated hooks, `phx-hook=".Name"` + `<script :type={Phoenix.LiveView.ColocatedHook} name=".Name">`

## Oban

Use **`ash_oban`** triggers on resources, not Oban directly:

```elixir
oban do
  triggers do
    trigger :my_trigger do
      scheduler_cron "@daily"
      action :do_thing
      where expr(should_do_thing)
      worker_module_name __MODULE__.Process.Worker
      scheduler_module_name __MODULE__.Process.Scheduler
    end
  end
end
```

See `deps/ash_oban/usage-rules.md`.

**Documented exception**: the Super Brain extraction enqueues (Brain.Page, Brain.Source, Memory, Files.Chunk, Drafts.Draft) use `Ash.Changeset.after_action` hooks calling `Oban.insert/1` directly rather than AshOban triggers. AshOban's trigger DSL wraps a single Ash resource action and cannot point at an external Oban worker; converting would require boilerplate `:extract_super_brain` actions on every resource without behavioral change. See `docs/superpowers/specs/2026-05-21-super-brain-iteration-2-design.md` "Post-iter2 update: deferred to after_action hooks" for the rationale and the conversion path if revisited.

## Localization

German uses **informal address** (du/dein, imperative `klicke`/`gib`), never formal (Sie/Ihr, `klicken Sie`). Edits go in `priv/gettext/de/LC_MESSAGES/`.

## Live E2E

Real LLM calls via OpenRouter through full agent pipeline. Requires `OPENROUTER_API_KEY` in `.env`; sandbox tests additionally need `SANDBOX_PROVIDER`, `NORTHFLANK_API_TOKEN`, `NORTHFLANK_PROJECT_ID`, `NORTHFLANK_FILE_SERVER_SECRET`.

Run via `bin/test-e2e-live` (auto-loads `.env`) or manually: `set -a && source .env && set +a && mix test.e2e.live`. Model: `openrouter:x-ai/grok-4.3` (registered in LLMDB custom models).

Scaffolding: `test/e2e_live/support/live_e2e_case.ex` (Ecto sandbox shared mode, real LLM client, test-scoped InstanceManager) and `assertions.ex` (`assert_tool_started`, `assert_response_complete`, etc.). Tags: `:e2e_live`, `:sandbox`, `:multiplayer`, `:auto_router`. Sandbox tests skip when probe fails.

<!-- usage-rules-start -->
<!-- usage-rules-header -->
# Usage Rules

**IMPORTANT**: Consult these usage rules early and often when working with the packages listed below.
Before attempting to use any of these packages or to discover if you should use them, review their
usage rules to understand the correct patterns, conventions, and best practices.
<!-- usage-rules-header-end -->

<!-- ash_phoenix-start -->
## ash_phoenix usage
_Utilities for integrating Ash and Phoenix_

[ash_phoenix usage rules](deps/ash_phoenix/usage-rules.md)
<!-- ash_phoenix-end -->
<!-- phoenix:ecto-start -->
## phoenix:ecto usage
[phoenix:ecto usage rules](deps/phoenix/usage-rules/ecto.md)
<!-- phoenix:ecto-end -->
<!-- phoenix:elixir-start -->
## phoenix:elixir usage
[phoenix:elixir usage rules](deps/phoenix/usage-rules/elixir.md)
<!-- phoenix:elixir-end -->
<!-- phoenix:html-start -->
## phoenix:html usage
[phoenix:html usage rules](deps/phoenix/usage-rules/html.md)
<!-- phoenix:html-end -->
<!-- phoenix:liveview-start -->
## phoenix:liveview usage
[phoenix:liveview usage rules](deps/phoenix/usage-rules/liveview.md)
<!-- phoenix:liveview-end -->
<!-- phoenix:phoenix-start -->
## phoenix:phoenix usage
[phoenix:phoenix usage rules](deps/phoenix/usage-rules/phoenix.md)
<!-- phoenix:phoenix-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

[ash_postgres usage rules](deps/ash_postgres/usage-rules.md)
<!-- ash_postgres-end -->
<!-- ash_ai-start -->
## ash_ai usage
_Integrated LLM features for your Ash application._

[ash_ai usage rules](deps/ash_ai/usage-rules.md)
<!-- ash_ai-end -->
<!-- igniter-start -->
## igniter usage
_A code generation and project patching framework_

[igniter usage rules](deps/igniter/usage-rules.md)
<!-- igniter-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A dev tool for Elixir projects to gather LLM usage rules from dependencies_

[usage_rules usage rules](deps/usage_rules/usage-rules.md)
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

[ash usage rules](deps/ash/usage-rules.md)
<!-- ash-end -->
<!-- req_llm-start -->
## req_llm usage
_req_llm_

[req_llm usage rules](deps/req_llm/usage-rules.md)
<!-- req_llm-end -->
<!-- ash_oban-start -->
## ash_oban usage
_The extension for integrating Ash resources with Oban._

[ash_oban usage rules](deps/ash_oban/usage-rules.md)
<!-- ash_oban-end -->
<!-- mdex-start -->
## mdex usage
_Fast and extensible Markdown for Elixir_

[mdex usage rules](deps/mdex/usage-rules.md)
<!-- mdex-end -->
<!-- ash_json_api-start -->
## ash_json_api usage
_The JSON:API extension for the Ash Framework._

[ash_json_api usage rules](deps/ash_json_api/usage-rules.md)
<!-- ash_json_api-end -->
<!-- ash_authentication-start -->
## ash_authentication usage
_Authentication extension for the Ash Framework._

[ash_authentication usage rules](deps/ash_authentication/usage-rules.md)
<!-- ash_authentication-end -->
<!-- usage-rules-end -->
