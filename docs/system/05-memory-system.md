# Memory System

Persistent memory storage with three scopes, automatic extraction, semantic context loading, Hebbian association, and consolidation.

## Overview

The memory system provides AI agents with persistent context that survives across conversation sessions. It uses a **direct action** architecture where memory operations are plain function calls and background jobs, with no dedicated memory agent process.

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
│       │    (loads key + semantic + associated memories into system prompt)       │
│       │                                                                          │
│       └──→ LLM generates response with memory context                          │
│                                                                                  │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│  Background (AshOban)                                                           │
│                                                                                  │
│  Every 1 min:  Conversation.extract_turn_memories trigger                       │
│                (where extraction_due_at < now AND NOT is_task_conversation)     │
│                     │                                                            │
│                     └──→ ExtractTurnMemories action ──→ creates/updates memories│
│                                                                                  │
│  Daily 3 AM:   User.consolidate_memories trigger                                │
│                (decay stale, promote local→user, merge duplicates)              │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Memory Scopes

Memories exist in three scopes:

| Scope | Atom | Scoped To | Use Cases | Unique On |
|-------|------|-----------|-----------|-----------|
| **Local** | `:local` | Conversation | Project context, task lists, bug investigations | `(conversation_id, name)` |
| **User** | `:user` | User × workspace bucket | Coding style, preferences, general facts | `(user_id, workspace_id, name)` |
| **Agent** | `:agent` | Custom Agent | Task state, processed items, pending approvals | `(custom_agent_id, name)` |

- Local memories require a `conversation_id`; their `workspace_id` is derived from the conversation on create.
- User memories are scoped to a `(user_id, workspace_id)` bucket. `workspace_id IS NULL` is the personal-context bucket and is fully isolated from every workspace bucket. Cross-conversation availability is controlled by `User.global_memory_enabled`.
- Agent memories persist across conversations and heartbeats for a specific CustomAgent; their `workspace_id` is derived from the agent on create.

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
- The user-scope identity is `(user_id, workspace_id, name)` with `nulls_distinct: false` — so `(alice, NULL, "preferences")` is unique within the personal bucket and coexists with `(alice, ws_red, "preferences")` and `(alice, ws_blue, "preferences")` as three distinct rows.
- `MemoryAssociation` (Hebbian edges) require both endpoints to share the same `workspace_id`.
- Workspace deletion **cascades** to its memories (`on_delete: :delete_all`) so the isolation invariant holds under deletion.

### How callers resolve the workspace_id

| Caller | Source |
|---|---|
| Memory tools (`SetMemory`, `SearchMemories`, `ForgetMemory`) | `ctx.workspace_id`, set by `Magus.Agents.Plugins.Support.Preflight` from the conversation |
| `BuildMemoryContext.build/1`, `ExtractTurnMemories`, the `ExtractMemories` reactor | `Magus.Memory.workspace_id_for_conversation/1` from the conversation_id |
| `PromoteMemoryCandidates`, `MergeMemories` | Per-bucket — driven by `ConsolidateMemories` (see below) |

Background-job actions (`PromoteMemoryCandidates`, `MergeMemories`) accept `workspace_id` as a required action input and operate on a single bucket per call. `ConsolidateMemories` discovers the user's buckets via a `SELECT DISTINCT workspace_id` and iterates them, never crossing bucket boundaries during promotion or merge. The LLM merge prompt explicitly labels the bucket so the model never sees memories from two workspaces in one request.

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
| `structured_data` | map | Optional unvalidated JSON for kind-specific fields (deadlines, streaks, sources, etc.) |
| `confidence` | float | 0.0–1.0 (default 1.0) |
| `is_active` | boolean | Soft delete flag |
| `last_accessed_at` | datetime | Bumped when memory is loaded into context |
| `lock_version` | integer | Optimistic locking for concurrent access |

## Context Loading Strategy

Context loading uses a **three-layer hierarchy** via `BuildMemoryContext.build/1`:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CONTEXT LOADING HIERARCHY                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Priority Order: key (recency) → semantic → associated                         │
│   (If a memory appears in multiple layers, shown once in highest-priority)      │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                      1. KEY LAYER (Most Recently Updated)               │   │
│   │                                                                          │   │
│   │   Top 3 local + top 3 user + top 3 agent memories by updated_at DESC    │   │
│   │   Full content included (name, summary, JSON content preview)           │   │
│   │   Ensures the most actively-worked-on memories are always present       │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                          │
│                                      ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                    2. SEMANTIC LAYER (Relevance-Based)                   │   │
│   │                                                                          │   │
│   │   Uses pgvector L2 distance (<->) on summary_embedding                  │   │
│   │   Query: incoming user message                                          │   │
│   │   Maximum 5 results (excluding key memories already included)           │   │
│   │   Summary-only format (name + summary, no full content)                 │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                          │
│                                      ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                    3. ASSOCIATED LAYER (Hebbian Expansion)               │   │
│   │                                                                          │   │
│   │   1-hop traversal of MemoryAssociation edges from key/semantic results  │   │
│   │   Up to 3 additional results                                            │   │
│   │   Brings in contextually related memories not matched by embedding      │   │
│   │                                                                          │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
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

Memory extraction is triggered by AshOban with a debounce mechanism:

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
│      → Load existing local + user memories for context                         │
│      → Send turn to LLM for structured extraction (JSON schema)               │
│      → Semantic dedup: check if similar memory exists (0.9 threshold)          │
│      → Create or update memories with appropriate scope                        │
│      → AshOban generates embeddings for new/updated summaries                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Consolidation (Scheduled)

Daily consolidation runs three steps. Promote and merge always operate **per workspace bucket** so memories never cross workspace boundaries during consolidation:

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
│   1. DECAY (workspace-agnostic; row-level deactivation)                        │
│      Find memories where COALESCE(last_accessed_at, updated_at) > 90 days     │
│      Deactivate stale memories (soft delete: is_active = false)               │
│                                                                                  │
│   2. Discover workspace buckets:                                                │
│      SELECT DISTINCT workspace_id FROM memories WHERE user_id = $1 AND active │
│                                                                                  │
│   3. PROMOTE per bucket (via PromoteMemoryCandidates)                          │
│      For each bucket, find local memories with similar names across           │
│      conversations *in the same bucket* and promote to :user scope.           │
│                                                                                  │
│   4. MERGE per bucket (via MergeMemories)                                      │
│      For each bucket, find near-duplicate :user memories *in that bucket*     │
│      and ask the LLM (with bucket label) which to merge. Local merges         │
│      remain per-conversation (already isolated to one workspace).             │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

The `magus.consolidate_memories` mix task accepts `--workspace <id|null|all>` to constrain consolidation to a single bucket (useful for debugging or partial reconsolidation).

## LLM Tools

Three memory tools are available to the LLM:

| Tool | Purpose |
|------|---------|
| `SearchMemories` | Semantic search when user asks "what do you remember about X?" |
| `SetMemory` | Create or update memories in any scope (local, user, agent). Supports `kind` and `structured_data` params. |
| `ForgetMemory` | Soft-delete a memory by name |

Other memory operations are automatic:

| Operation | Mechanism |
|-----------|-----------|
| Context loading | `BuildMemoryContext.build()` called before each LLM turn |
| Memory extraction | AshOban trigger after conversation pauses (60s debounce) |
| Memory decay | AshOban daily consolidation |
| Memory promotion | AshOban daily consolidation |
| Memory merge | AshOban daily consolidation |

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
@max_associated 3         # Max 1-hop Hebbian association results
# Key layer: top 3 per scope (hardcoded in read actions)
# Stale threshold: 90 days (in ConsolidateMemories)
```

## AshOban Triggers Summary

| Trigger | Resource | Cron | Condition | Action |
|---------|----------|------|-----------|--------|
| `:extract_turn_memories` | Conversation | `*/1 * * * *` | `needs_extraction AND NOT is_task_conversation` | Load last turn, run `ExtractTurnMemories` |
| `:consolidate_memories` | User | `0 3 * * *` | `global_memory_enabled` | Decay stale + promote local to user + merge duplicates |
| `:generate_embedding` | Memory | on-demand | `summary != nil` | Generate pgvector embedding for summary |

## Key Files Reference

| File | Purpose |
|------|---------|
| `lib/magus/memory/memory_resource.ex` | Memory Ash resource with scopes, attributes, actions |
| `lib/magus/memory/memory.ex` | Memory domain with code interfaces and `workspace_id_for_conversation/1` helper |
| `lib/magus/memory/memory/changes/derive_workspace_from_conversation.ex` | Derives `workspace_id` from parent conversation on `:local` create |
| `lib/magus/memory/memory/changes/derive_workspace_from_custom_agent.ex` | Derives `workspace_id` from parent custom agent on `:agent` create |
| `lib/magus/memory/memory_association/validations/same_workspace.ex` | Enforces same-workspace for Hebbian edges |
| `lib/magus/memory/signals.ex` | PubSub helpers for real-time UI updates |
| `lib/magus/agents/actions/build_memory_context.ex` | Three-layer context loading |
| `lib/magus/agents/actions/extract_turn_memories.ex` | Turn-level extraction with LLM |
| `lib/magus/agents/actions/consolidate_memories.ex` | Daily decay + promotion + merge |
| `lib/magus/agents/actions/promote_memory_candidates.ex` | Cross-conversation pattern promotion |
| `lib/magus/agents/actions/merge_memories.ex` | Duplicate memory merging |
| `lib/magus/agents/tools/memory/search_memories.ex` | LLM tool for explicit search |
| `lib/magus/agents/tools/memory/set_memory.ex` | LLM tool for create/update |
| `lib/magus/agents/tools/memory/forget_memory.ex` | LLM tool for soft-delete |
| `lib/magus/agents/context/builder.ex` | Invokes BuildMemoryContext during pre-flight |
| `lib/magus/chat/conversation/changes/extract_turn_memories.ex` | AshOban change for extraction trigger |
| `lib/magus/chat/message/changes/signal_agent.ex` | Schedules extraction on user message |
| `lib/magus/files/embedding_model.ex` | Embedding generation |
