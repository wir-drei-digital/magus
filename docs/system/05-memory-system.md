# Memory System

Persistent memory storage with three scopes, per-turn local extraction, semantic context loading, and nightly profile distillation.

## Overview

The memory system gives AI agents lightweight, durable context: who the user is, what is going on in this conversation, and a small set of durable user facts. It is not a knowledge store; topic-specific knowledge lives in Brains, and the Super Brain graph is the smart-retrieval layer built on top of memories (and other resources) as one of its Layer 0 sources. Memory operations are plain function calls and background jobs, with no dedicated memory agent process.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              MEMORY ARCHITECTURE                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  User Message                                                                   │
│       │                                                                          │
│       ├──→ SignalAgent sets extraction_due_at on Conversation                   │
│       │                                                                          │
│       ▼                                                                          │
│  ConversationAgent (ReactStrategy + Plugins)                                    │
│       │                                                                          │
│       ├──→ BuildMemoryContext.build() ── direct function call ──→ DB queries    │
│       │    (loads key + semantic memories, or the profile document, per scope)   │
│       │                                                                          │
│       └──→ LLM generates response with memory context                          │
│                                                                                  │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  Background (AshOban)                                                           │
│                                                                                  │
│  Every 1 min:  Conversation.extract_turn_memories trigger                       │
│                (where extraction_due_at < now AND NOT is_task_conversation)     │
│                     │                                                            │
│                     └──→ ExtractTurnMemories action ──→ creates/updates LOCAL    │
│                          memories only, then evicts oldest past the cap          │
│                                                                                  │
│  Daily 3 AM:   User.consolidate_memories trigger                                │
│                (rewrite the distilled user profile per workspace bucket)        │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Memory Scopes

Memories exist in three scopes:

| Scope | Atom | Scoped To | Use Cases | Unique On |
|-------|------|-----------|-----------|-----------|
| **Local** | `:local` | Conversation | Project context, task lists, bug investigations | `(conversation_id, name)` |
| **User** | `:user` | User × workspace bucket | Explicit "remember this everywhere" facts | `(user_id, workspace_id, name)` |
| **Agent** | `:agent` | Custom Agent | Task state, processed items, pending approvals | `(custom_agent_id, name)` |

- Local memories require a `conversation_id`; their `workspace_id` is derived from the conversation on create. Local is the default destination for everything: per-turn extraction writes local only, and the `set_memory` tool defaults its `scope` param to `"local"`.
- User memories are scoped to a `(user_id, workspace_id)` bucket and hold **only** explicit writes: a user-scope `set_memory` call made on an explicit cross-cutting signal ("always", "generally", "for all my projects", "remember this everywhere"), or a fact folded in by the nightly profile distiller. There is no ambient per-turn path into the user bucket. `workspace_id IS NULL` is the personal-context bucket and is fully isolated from every workspace bucket. Cross-conversation availability is controlled by `User.global_memory_enabled`.
- Agent memories persist across conversations and heartbeats for a specific CustomAgent; their `workspace_id` is derived from the agent on create. Agent-scope memories are never distilled into the user profile.

## Workspace Scoping

Every memory carries a nullable `workspace_id`. It is purely an isolation key: there is **no** sharing of memories across users via grants. The column exists so that a single user's memories never leak between workspaces they belong to.

```
┌──────────────────────────────────────────────────────────────────┐
│                   WORKSPACE ISOLATION                             │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│   user_id │ workspace_id │ scope  │ visible to                   │
│   ───────┼──────────────┼────────┼──────────────────────────────│
│   alice  │   ws_red     │ :user  │ alice when in ws_red only    │
│   alice  │   ws_blue    │ :user  │ alice when in ws_blue only   │
│   alice  │   NULL       │ :user  │ alice in personal mode only  │
│   alice  │ <conv.ws>    │ :local │ conversation members         │
│   alice  │ <agent.ws>   │ :agent │ owner only (or AI agent)     │
│                                                                   │
│   Read actions ALWAYS take a workspace_id argument and filter    │
│   with NULL-safe equality. The personal bucket (NULL) is never   │
│   joined with any workspace bucket.                              │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Key invariants

- `workspace_id` is **derived** for `:local` (from `conversation.workspace_id`) and `:agent` (from `custom_agent.workspace_id`) on create. The derive change rejects an explicit mismatched value.
- `:user` create takes `workspace_id` as an explicit action argument (`nil` allowed).
- The user-scope identity is `(user_id, workspace_id, name)` with `nulls_distinct: false`, so `(alice, NULL, "preferences")` is unique within the personal bucket and coexists with `(alice, ws_red, "preferences")` and `(alice, ws_blue, "preferences")` as three distinct rows.
- Workspace deletion **cascades** to its memories (`on_delete: :delete`) so the isolation invariant holds under deletion.

### How callers resolve the workspace_id

| Caller | Source |
|---|---|
| User-scope memory tools (`SetMemory`, `SearchMemories`, `ForgetMemory`) | `Magus.Agents.Tools.Memory.Helpers.resolve_user_bucket/1`: derives the bucket from `ctx.conversation_id` when present (the conversation's `workspace_id`, `nil` included, is authoritative; a missing conversation is a tool error, never a silent Personal write); falls back to a present `ctx.workspace_id` key only when there is no conversation in context |
| `BuildMemoryContext.build/1`, `ExtractTurnMemories`, `DistillUserProfile` | `Magus.Memory.workspace_id_for_conversation/1` (or the tagged `fetch_workspace_id_for_conversation/1`) from the conversation_id |

`resolve_user_bucket/1` is the single resolver for all user-scope tool operations, including the upsert lookup in `find_memory_by_name/3`. This closed the bug where a user-scope write made while working in a workspace could silently land in the Personal bucket when the tool context lacked `workspace_id`: the conversation is now the source of truth, and the context value is only a fallback for tool calls with no conversation in scope (e.g. heartbeat wakeups).

## Memory Resource

The `Magus.Memory.Memory` resource stores all memories:

| Attribute | Type | Description |
|-----------|------|-------------|
| `name` | string | Topic identifier (unique per scope) |
| `summary` | string | Searchable description (max 500 chars) |
| `summary_embedding` | vector(1536) | pgvector embedding for semantic search |
| `content` | map | Structured JSON data (max 8,000 chars) |
| `scope` | atom | `:local`, `:user`, or `:agent` |
| `kind` | atom | `:general`, `:fact`, `:hypothesis`, `:observation`, `:summary`, `:preference`, `:goal`, `:topic`, `:habit`, `:reflection` |
| `lock_version` | integer | Optimistic locking for concurrent access |

Deletes are hard deletes through the resource's `:destroy` action (see "Deletion" below); there is no soft-delete flag, no confidence score, no unvalidated `structured_data` bag, and no `last_accessed_at` touch. `kind` is the only classification left, and it exists to give the distiller light structure and to power the settings-UI filter.

## Context Loading Strategy

Context loading uses a **two-layer hierarchy** via `BuildMemoryContext.build/1`, with an optional profile document that replaces the user key layer:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CONTEXT LOADING HIERARCHY                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Priority Order: profile (if enabled) or key (recency) → semantic              │
│   (If a memory appears in multiple layers, shown once in highest-priority)      │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │              0. PROFILE (when profile_enabled and global_enabled)       │   │
│   │                                                                          │   │
│   │   The distilled user-profile document for this workspace bucket         │   │
│   │   Replaces the top-3-recency user key layer below when present          │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                          │
│                                      ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                      1. KEY LAYER (Most Recently Updated)               │   │
│   │                                                                          │   │
│   │   Top 3 local + top 3 agent memories by updated_at DESC, plus top 3     │   │
│   │   user memories only when no profile document is available              │   │
│   │   Full content included (name, summary, JSON content preview)           │   │
│   │   Ensures the most actively-worked-on memories are always present       │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                          │
│                                      ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                    2. SEMANTIC LAYER (Relevance-Based)                   │   │
│   │                                                                          │   │
│   │   Uses pgvector L2 distance (<->) on summary_embedding, per scope       │   │
│   │   Query: incoming user message                                          │   │
│   │   Maximum 5 results per scope (excluding key memories already included) │   │
│   │   Summary-only format (name + summary, no full content)                 │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│   Whole-block budget: 6,000 chars. If full previews blow past the cap, the      │
│   block re-renders with summary-only key memories.                             │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Invocation

Context loading is a synchronous function call from the Builder (pre-flight):

```elixir
# In Magus.Agents.Context.Builder
memory_context = BuildMemoryContext.build(%{
  user_id: user_id,
  conversation_id: conversation_id,
  custom_agent_id: custom_agent_id,
  query_text: user_message_text,
  global_enabled: user.global_memory_enabled
})
```

No agent signals, no timeouts. The result is injected into the system prompt.

## Memory Extraction Flow

Memory extraction is triggered by AshOban with a debounce mechanism. Every extraction lands as a **local** memory; there is no scope decision left to make at extraction time, and the extraction prompt no longer offers a `scope` field.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         MEMORY EXTRACTION FLOW                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   1. User sends message                                                         │
│      → SignalAgent sets extraction_due_at = now + 60 seconds                   │
│      (rapid messages keep pushing extraction_due_at forward)                    │
│                                                                                  │
│   2. AshOban scheduler runs every minute                                        │
│      → Finds conversations where extraction_due_at < now                       │
│      → Excludes task conversations (is_task_conversation = false)              │
│                                                                                  │
│   3. Worker fires for each due conversation                                     │
│      → Clear extraction_due_at (prevents re-fire)                              │
│      → Load last user message + agent response                                 │
│      → Skip if messages too short                                              │
│      → Call ExtractTurnMemories action async                                   │
│                                                                                  │
│   4. ExtractTurnMemories action                                                 │
│      → Load existing local memories (for updates) and the user-bucket listing  │
│        (shown to the LLM as "already known, do not re-extract")                │
│      → Send turn to LLM for structured extraction (JSON schema, local only)   │
│      → Semantic dedup: check if similar local memory exists (0.9 threshold)    │
│      → Create or update local memories; merge or replace per update_mode       │
│      → Enforce the per-conversation cap: evict oldest-updated local rows       │
│        through the real :destroy action once the conversation exceeds it       │
│      → AshOban generates embeddings for new/updated summaries                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Growth bound: per-conversation cap

Local-memory growth is bounded deterministically instead of by a time-based sweep. `Magus.Config.max_memories_per_conversation/0` (default 20) is enforced at the end of every extraction: once a conversation's local-memory count exceeds the cap, the least-recently-updated rows are destroyed through the same `:destroy` action used everywhere else, so PubSub and Super Brain retraction fire normally. There is no other pruning: no time-based decay, no background sweep touches user- or agent-scope rows at all.

## Profile Distillation (Scheduled)

Daily consolidation runs a single step: rewriting the distilled user-profile document per workspace bucket. The nightly distiller is the **sole ambient curator** of durable, cross-cutting facts; there is no promotion pipeline and no merge pipeline left to run alongside it.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CONSOLIDATION FLOW                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   AshOban Scheduler on User resource (daily at 3 AM)                           │
│   Triggers for each user with global_memory_enabled == true                    │
│                                                                                  │
│   ConsolidateMemories Action:                                                   │
│                                                                                  │
│   1. Discover workspace buckets:                                                │
│      SELECT DISTINCT workspace_id FROM memories WHERE user_id = $1             │
│                                                                                  │
│   2. DISTILL per bucket (via DistillUserProfile), gated by profile_enabled     │
│      Input: the bucket's current profile document + pending_notes +            │
│      local memories updated since last_distilled_at in that bucket             │
│      (capped at 100 rows of name + summary, most recently updated first)       │
│      The LLM REWRITES the whole document under a hard token cap, which is      │
│      what resolves contradictions and drops stale/one-off information.         │
│      A UserProfileVersion snapshot is kept on every distill and reset.         │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Durable facts reach the profile directly from local memories; there is no episodic middle step and no repetition-across-conversations heuristic. The `update_profile` tool's `pending_notes` path is the fast lane for durable facts an agent notices mid-conversation, feeding the same distiller input. Explicit user-scope `set_memory` writes bypass the profile entirely and stay as individually deletable rows.

The `magus.consolidate_memories` mix task accepts `--workspace <id|null|all>` to constrain consolidation to a single bucket (useful for debugging or partial reconsolidation).

## Deletion

Deletes are **hard deletes**, not soft deletes. The `:destroy` action:

- Broadcasts `memory_deleted` via PubSub so open UIs stay consistent.
- Enqueues a `Magus.SuperBrain.Workers.RetractResource` job (`resource_type: :memory`). The worker deletes the Postgres `Episode` rows for that memory, which cascades to `Claim` rows via `on_delete: :delete`, removing the facts from claims-backed retrieval (dossier, trust tiers), and best-effort deletes the matching Episode node in the routed Layer 1 graph. Local memories are never extracted into the graph, so this only fires for `:user` and `:agent` scope.
- Is irreversible: there is no undo, no `is_active` flag to flip back, and re-creating a memory with the same name after a delete succeeds cleanly under the scope-only unique indexes.

This applies uniformly whether the delete comes from `ForgetMemory` (AI-driven, acts as the system actor), the extraction cap-eviction path, or a user-initiated delete via the settings UI RPC.

## LLM Tools

Three memory tools are available to the LLM:

| Tool | Purpose |
|------|---------|
| `SearchMemories` | Semantic search when user asks "what do you remember about X?" |
| `SetMemory` | Create or update memories. Defaults to `scope: "local"`; `"user"` scope is reserved for explicit cross-cutting signals from the user ("always", "generally", "remember this everywhere"). Supports `kind`. |
| `ForgetMemory` | Hard-delete a memory by name (permanent) |

Other memory operations are automatic:

| Operation | Mechanism |
|-----------|-----------|
| Context loading | `BuildMemoryContext.build()` called before each LLM turn |
| Memory extraction | AshOban trigger after conversation pauses (60s debounce); local scope only |
| Profile distillation | AshOban daily consolidation |

There is no background promotion and no background merge: those pipelines were removed, and no background process silently deletes memories.

## Real-Time UI Updates

Memory changes broadcast events via `Magus.Memory.Signals`:

```elixir
# PubSub topic
"memory:{user_id}"

# Events
%{type: "memory_created", key: name, memory_id: id, scope: "local"|"user"|"agent"}
%{type: "memory_updated", key: name, memory_id: id, scope: "local"|"user"|"agent"}
%{type: "memory_deleted", key: name, memory_id: id, scope: "local"|"user"|"agent"}
```

## Embedding Generation

Memory summaries are embedded using the configured embedding model:

```elixir
# Config
config :magus, :agents, embedding_model: "openai/text-embedding-3-small"
```

Embeddings are:
- 1536 dimensions
- Generated asynchronously via AshOban trigger on memory create/update
- Stored in `summary_embedding` column
- Searched using pgvector L2 distance (`<->` operator)

## Configuration

```elixir
# config/config.exs
config :magus, :agents,
  embedding_model: "openai/text-embedding-3-small",
  summary_model: "openrouter:anthropic/claude-haiku-4.5"  # also used as extraction model fallback

# Memory budgets (in BuildMemoryContext)
@max_semantic_results 5   # Max semantic search results per scope
@max_block_chars 6000     # Whole-block context budget
# Key layer: top 3 per scope (hardcoded in read actions)

# Growth bound (in ExtractTurnMemories, via Magus.Config)
config :magus, Magus.Memory, max_memories_per_conversation: 20
```

## AshOban Triggers Summary

| Trigger | Resource | Cron | Condition | Action |
|---------|----------|------|-----------|--------|
| `:extract_turn_memories` | Conversation | `*/1 * * * *` | `needs_extraction AND NOT is_task_conversation` | Load last turn, run `ExtractTurnMemories` (local only, then cap eviction) |
| `:consolidate_memories` | User | `0 3 * * *` | `global_memory_enabled` | Distill the user profile per workspace bucket |
| `:generate_embedding` | Memory | on-demand | `summary != nil` | Generate pgvector embedding for summary |

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/magus/memory/memory_resource.ex` | Memory Ash resource with scopes, attributes, actions |
| `lib/magus/memory/memory.ex` | Memory domain with code interfaces, `workspace_id_for_conversation/1` and `fetch_workspace_id_for_conversation/1` helpers |
| `lib/magus/memory/memory/changes/derive_workspace_from_conversation.ex` | Derives `workspace_id` from parent conversation on `:local` create |
| `lib/magus/memory/memory/changes/derive_workspace_from_custom_agent.ex` | Derives `workspace_id` from parent custom agent on `:agent` create |
| `lib/magus/memory/signals.ex` | PubSub helpers for real-time UI updates |
| `lib/magus/agents/actions/build_memory_context.ex` | Two-layer context loading (plus optional profile) |
| `lib/magus/agents/actions/extract_turn_memories.ex` | Turn-level extraction with LLM (local only) + cap eviction |
| `lib/magus/agents/actions/consolidate_memories.ex` | Daily profile distillation trigger |
| `lib/magus/agents/actions/distill_user_profile.ex` | Rewrites the distilled profile document per bucket |
| `lib/magus/agents/tools/memory/search_memories.ex` | LLM tool for explicit search |
| `lib/magus/agents/tools/memory/set_memory.ex` | LLM tool for create/update (defaults to local) |
| `lib/magus/agents/tools/memory/forget_memory.ex` | LLM tool for hard delete |
| `lib/magus/agents/tools/memory/helpers.ex` | `resolve_user_bucket/1` and other tool-shared helpers |
| `lib/magus/agents/context/builder.ex` | Invokes BuildMemoryContext during pre-flight |
| `lib/magus/chat/conversation/changes/extract_turn_memories.ex` | AshOban change for extraction trigger |
| `lib/magus/chat/message/changes/signal_agent.ex` | Schedules extraction on user message |
| `lib/magus/super_brain/workers/retract_resource.ex` | Deletes Episode/Claim rows and the graph node on memory destroy |
| `lib/magus/files/embedding_model.ex` | Embedding generation |
