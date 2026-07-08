# Memory v2: Repair + Simplification Design

**Date:** 2026-07-08
**Status:** Approved direction (option B: repair + simplify), spec pending review

## Product framing

Memory is the lightweight layer that keeps an agent *relevant*: who the user is, what is going on in this conversation, and a small set of durable user facts. It is not a knowledge store. Topic-specific knowledge lives in Brains, and the distilled **user profile** is the primary user-level artifact. Episodic memory rows exist to feed the profile and to give conversations continuity, nothing more.

The **Super Brain** sits above all of this as the smart-retrieval layer: it builds a graph of facts, claims, and relationships across resources (memories included). It is still in development, which cuts two ways for this spec: memory must be correct and useful entirely on its own (no retrieval feature here may depend on the graph), and integration points stay minimal and cheap (enqueue on write, retract on destroy) rather than deep, because the graph is a derived, disposable index that is still changing shape.

Consequences of this framing:

- The **local** scope (conversation) is the workhorse and the default destination for everything extracted.
- The **user** bucket is small and curated: it holds only explicit "remember this everywhere" writes. Durable facts otherwise reach the user level through nightly profile distillation, never through ambient per-turn extraction.
- Machinery that does not serve relevance (provenance tables, version history, association graphs, unused metadata) is removed rather than finished.

## Problems this fixes

1. **Workspace bug (reported):** user-scope memories created while working in a workspace end up in the Personal bucket. Root cause analysis (2026-07-08 deep dive): every current write path *does* propagate `workspace_id` correctly, but the bucket is inherited from `conversation.workspace_id`, and there is no server-side guardrail for user scope. `set_memory` falls back to `nil` silently when the tool context lacks the key (`lib/magus/agents/tools/memory/set_memory.ex:152`), and the `:create_user` action accepts `nil` without derivation or validation, while `:local` and `:agent` scopes both have `Derive*` guard changes. Pre-2026-04-25 rows were additionally backfilled to NULL by design.
2. **Scope over-assignment:** the agent puts too much into the user bucket. Two causes: `set_memory` defaults `scope` to `"user"` and its description promotes that default; the extraction prompt's bar for user scope is two vague lines ("general facts about the user"). Meanwhile a curated promotion gate (`PromoteMemoryCandidates`) exists but is bypassed, and on inspection its criterion (repetition across >= 2 conversations plus 0.85 embedding similarity) is a weak proxy for durability anyway: durable facts often appear exactly once, and short summaries phrased differently rarely clear 0.85.
3. **Dead or half-wired machinery:** `memory_sources` has zero rows ever; `memory_versions` and `user_profile_versions` are written on every change and read nowhere; `changed_by` attribution always collapses to `:system`; `confidence` and `structured_data` are stored but never used; the Hebbian association layer (reinforcement writes on every context build, read-time decay, 1-hop expansion) is live but of unproven retrieval value and lets local memories from one conversation bleed into another via edges.

## Locked decisions

- Direction **B**: repair + structural simplification (user answer 2026-07-08).
- Remove the Hebbian association layer entirely.
- Remove `MemoryVersion` and `UserProfileVersion`; **hard deletes are acceptable** (user's words), so soft-delete goes too.
- Existing misfiled personal-bucket rows are left as-is (no reliable provenance to re-bucket them); users delete them via the settings UI.
- Second-round decisions (user, 2026-07-08): the nightly **distiller becomes the sole ambient curator** of durable facts (the promotion pipeline is removed rather than tuned); the **90-day decay is removed entirely** along with the `last_accessed_at` touch machinery; local-memory growth is bounded by enforcing the existing per-conversation cap instead.

## Design

### 1. Workspace correctness

**Tools derive the bucket from the conversation; the context value is only a fallback.**

- A single resolver, `Magus.Agents.Tools.Memory.Helpers.resolve_user_bucket(ctx)`, owns bucket resolution for all user-scope tool operations (`set_memory`, `search_memories`, `forget_memory`, including the upsert lookup in `find_memory_by_name/3`). Its contract distinguishes the three cases the current helpers collapse:
  - `ctx.conversation_id` present and the conversation exists: `{:ok, conversation.workspace_id}` (`nil` here legitimately means a personal conversation). Backed by a new tagged variant `Magus.Memory.fetch_workspace_id_for_conversation/1` returning `{:ok, workspace_id | nil} | {:error, :not_found}`; the existing nil-collapsing `workspace_id_for_conversation/1` is not used by tools anymore.
  - `ctx.conversation_id` present but the conversation lookup fails: `{:error, :conversation_not_found}`. This becomes a tool error result, never a silent Personal write.
  - No `conversation_id`: fall back to the context value only if the key is actually present (`Map.has_key?(ctx, :workspace_id)`, checking both atom and string keys); a present `nil` is an explicit Personal choice. If neither key exists: `{:error, :no_bucket_context}`, returned as a tool error.
- `update_profile` switches to the same resolver for consistency.
- Extraction (`lib/magus/agents/actions/extract_turn_memories.ex:214`) already derives correctly; unchanged.
- No changes to conversation creation: SPA (`frontend/src/lib/stores/workbench.svelte.ts:376`) and classic both pass the active workspace already.

### 2. Scope discipline

**Extraction writes local only.**

- Remove `scope` from the extraction output schema and prompt in `extract_turn_memories.ex`. All extractions apply as local memories. Delete `apply_user_extraction/6`, `create_user_memory/6` (extraction-local helper), the `allow_global` downgrade branch, and the user-scope semantic-dedup path within extraction.
- The prompt is rewritten around: extract facts, decisions, and context relevant to *this conversation's continuity*; dedup against the listed existing memories (the existing user-bucket listing stays in the prompt as "already known about the user, do not re-extract"); `update_mode` merge/replace semantics stay; "keep extractions minimal" stays.
- **A per-conversation cap replaces time decay as the growth bound.** The existing `max_memories_per_conversation` config (default 20, accessor `Magus.Config.max_memories_per_conversation/0`, currently dead: nothing enforces it) is enforced at extraction-apply time: when applying extractions pushes a conversation's local-memory count over the cap, the least recently updated local rows are destroyed through the same `:destroy` action, so PubSub and retraction fire. Deterministic, conversation-scoped eviction instead of a global clock.

**The profile is the sole ambient path to durability; the promotion pipeline is removed.**

Repetition plus embedding similarity is a proxy for durability, and a weak one, so the gate is removed rather than tuned:

- `DistillUserProfile` becomes the single ambient curator. Its input changes from the user bucket to: the current profile document + `pending_notes` + local memories touched since `last_distilled_at` in the matching workspace bucket (the personal bucket reads nil-workspace locals), capped at 100 rows of name + summary, most recently updated first. Durable facts flow local to profile directly, with no episodic middle step. Agent-scope memories stay out of distillation, as today.
- `PromoteMemoryCandidates` and `MergeMemories` are deleted (with an explicit-only user bucket and upsert-by-name, there is nothing left to merge). The `:promote_to_user` action and the `promote_memory_to_user` domain interface go with them.
- The user bucket holds only explicit writes: `set_memory` user scope on an explicit cross-cutting signal, per the tool contract above. The `update_profile` pending-notes path remains the fast lane for durable facts the agent notices mid-conversation.
- Nightly consolidation shrinks to profile distillation alone (decay is also removed, see section 3); `ConsolidateMemories` keeps its trigger but loses the decay, promote, and merge steps.

Accepted tradeoff: facts distilled into the profile lose row granularity in the settings UI (the profile can only be reset, not line-deleted). Explicit user-scope rows keep granular delete.

**`set_memory` defaults to local.**

- Default `scope` param flips from `"user"` to `"local"` (`set_memory.ex:89`).
- Tool description rewritten: local is the default; user scope requires an explicit cross-cutting signal from the user ("always", "generally", "for all my projects", "remember this everywhere"). The agent-isolation gate (`can_write_global_memories`) stays.

### 3. Removals

**Resources and tables dropped** (code, domain interfaces, policies, tests, then one migration):

| Removed | Notes |
|---|---|
| `Magus.Memory.MemoryAssociation` (+ `memory_associations` table) | Also delete `SameWorkspace` validation, domain interfaces (`create_memory_association`, `reinforce_association`, `get_associations_for_memory`, `get_association_between`), the association-expansion layer and `reinforce_co_retrieved/1` in `BuildMemoryContext` (`lib/magus/agents/actions/build_memory_context.ex:355-435`), and the three `memory_association*_test.exs` files. |
| `Magus.Memory.MemoryVersion` (+ `memory_versions` table) | Also delete `Memory.Changes.CreateVersion` and its wiring on `:create`, `:set`, `:clear`, `:promote_to_user`. Optimistic locking (`lock_version`) stays. |
| `Magus.Memory.MemorySource` (+ `memory_sources` table) | Zero rows ever written; no writer exists. |
| `Magus.Memory.UserProfileVersion` (+ `user_profile_versions` table) | Also delete `UserProfile.Changes.CreateVersion` and its wiring on `:set_document` and `:clear`. Profile "Reset" keeps working, it just stops snapshotting. |

**Columns dropped from `memories`:**

| Column | Notes |
|---|---|
| `is_active` | Soft-delete replaced by hard delete (below). |
| `confidence` | Never used for ranking or filtering; remove from tool params (`set_memory`), search-tool output, `USER_MEMORY_FIELDS` + the confidence line in the settings expand panel (`frontend/src/routes/settings/memory/+page.svelte`), the custom-agent `update_agent_memory` action argument and `memory_map/1` output (`lib/magus/agents/custom_agent.ex:338`), and the corresponding agent-memory types/wrappers in `frontend/src/lib/ash/api.ts` (around line 3444). |
| `structured_data` | Accepted, never read. Remove from tool params and action accepts. |
| `last_accessed_at` | Existed only to feed the 90-day decay filter. With decay removed, the column goes, along with the `touch_accessed/1` raw-SQL helper in the domain, the touch calls in `SearchMemories` and `BuildMemoryContext`, and the `[conversation_id, last_accessed_at]` index. |

`kind` stays (visible in the UI, gives the distiller light structure). `summary_embedding` and `lock_version` stay.

**Pipeline modules removed:** `PromoteMemoryCandidates`, `MergeMemories`, and the `decay_stale_memories/2` step in `ConsolidateMemories`. The 90-day decay is removed entirely, not scope-limited: local growth is bounded by the per-conversation cap (section 2), user and agent buckets are small and explicitly curated, and after this change **no background process silently deletes memories at all**, which is itself a trust property.

**Additional call sites in the removal checklist** (compile-breaking if missed):

- `lib/magus/accounts/data_export.ex` (`memories/1`): drop the `[:versions, :sources]` load, the `is_active == true` filter, and the `structured_data` / `confidence` fields from the export map.
- A repo-wide grep for `is_active`, `confidence`, `structured_data`, `deactivate_memory`, `last_accessed_at`, `touch_accessed`, `promote_memory_to_user`, `PromoteMemoryCandidates`, `MergeMemories`, `MemoryVersion`, `MemorySource`, `MemoryAssociation`, `UserProfileVersion` is part of the implementation plan's final verification, not left to chance.

**Soft delete becomes hard delete.**

- The `:deactivate` action is replaced by a custom `:destroy` action carrying `BroadcastMemoryEvent` (so `memory_deleted` PubSub still fires) and the Super Brain retraction enqueue (below).
- **Policy change:** the AI-agent bypass on the memory resource currently covers only `[:read, :create, :update]` (`lib/magus/memory/memory_resource.ex:408`); `:destroy` joins the bypass, otherwise `ForgetMemory` (which acts as `ai_actor()`) and the extraction cap-eviction path would be denied. User-initiated destroys via RPC stay covered by the existing creator-only destroy policy.
- **Super Brain retraction (destroy must actually forget):** deactivation today leaves derived graph data untouched, and `ExtractMemory.load/1` returns `:memory_not_found` for deleted rows, so re-extraction cannot heal anything. Destroy therefore enqueues a new `Magus.SuperBrain.Workers.RetractResource` job with `(resource_type: :memory, resource_id)`. The worker: (1) deletes the Postgres `Episode` rows for that resource, which cascades to `Claim` rows via the existing `on_delete: :delete` reference, removing the facts from claims-backed retrieval (dossier, trust tiers); (2) best-effort `DETACH DELETE`s the matching `(:Episode {resource_id})` node in the routed L1 graph (orphaned entity nodes are acceptable). L2 super-graph edges derived from the deleted claims may persist until the next replay or migration sweep; that residual staleness is explicitly accepted and bounded, because the canonical claims store is already clean. The worker is generic over `resource_type` so future hard-delete paths (drafts, files) can reuse it.
- All `is_active == true` filters drop out of the read actions. The three unique identities lose their `is_active` predicate and become partial-on-scope unique indexes: `[conversation_id, name] WHERE scope = 'local'`, `[user_id, workspace_id, name] (nils_distinct: false) WHERE scope = 'user'`, `[custom_agent_id, name] WHERE scope = 'agent'`.
- **Migration pre-clean:** before dropping the `is_active` column and rebuilding the unique indexes, the migration runs `DELETE FROM memories WHERE is_active = false`; otherwise old inactive duplicates can violate the new scope-only indexes.
- Callers updated: `ForgetMemory` tool, the cap-eviction path in extraction, and the `deactivate_user_memory` RPC, which becomes `destroy_user_memory` (SPA `deactivateUserMemory` wrapper and the settings-page delete follow; UI copy must say the deletion is permanent).
- `mix ash_typescript.codegen` regenerates `ash_rpc.ts` after the RPC change.

### 4. Unchanged (explicitly)

Watermark all-turns extraction with Oban retries; semantic dedup at extraction (0.9) for local; pgvector semantic search; context injection layers minus associations (key recency top-3 per scope + semantic top-5 per scope, 6KB cap, profile replaces the user key-layer when enabled); the distiller's contradiction handling, token budget, and `pending_notes` mechanism (only its input window changes); per-user `global_memory_enabled` / `profile_enabled` gating; workspace-bucket read filters; the memory settings UI structure (toggles, bucket filter, list, expand, profile card).

## Out of scope

- Re-bucketing existing personal-bucket rows (no provenance; manual deletion via UI).
- Conversation-creation UX around workspace context (wiring verified correct in SPA and classic).
- Any classic-workbench UI changes.
- Per-workspace memory toggles, admin profile flags (unchanged from the 2026-07-04 settings design).
- Brains / Super Brain changes beyond the new `RetractResource` retraction worker (graphs remain derived and rebuildable).

## Verification

- **Eval-gated:** `mix magus.eval longmemeval --limit 18` before and after the Phase 2 removals; the 3/18 hardened baseline must not regress (this specifically watches the association-layer and promotion removals). `MIX_ENV=test mix magus.eval profile_distill` must hold 6/6 and gains a fixture case covering the new local-memory input window. Yardstick note: LongMemEval measures cross-session episodic recall, which is the Super Brain's long-term job, not this layer's; it stays here as a regression tripwire, while the profile eval and the trust invariants below are this layer's primary quality metrics.
- **New regression tests:**
  - user-scope `set_memory` in a workspace conversation lands in that workspace bucket even when the tool context omits `workspace_id` (pins the reported bug);
  - user-scope `set_memory` with neither `conversation_id` nor `workspace_id` in context returns a tool error, not a Personal-bucket write;
  - user-scope `set_memory` with a `conversation_id` whose conversation does not exist returns a tool error, not a Personal-bucket write;
  - extraction never creates `scope: :user` rows;
  - `ForgetMemory` (as `ai_actor()`) successfully destroys a memory (pins the destroy policy bypass);
  - destroying a memory enqueues `RetractResource`, and the worker deletes the matching `Episode` rows (claims cascade) and issues the graph episode delete;
  - the distiller receives the bucket-scoped input window (profile + pending notes + capped recent locals) and folds a durable local fact into the profile document;
  - extraction cap eviction destroys the least recently updated local rows once a conversation exceeds `max_memories_per_conversation`;
  - hard-delete then re-create with the same name succeeds under the new unique indexes;
  - invariant: no background process deletes user-scope rows (only explicit user or agent destroys touch the user bucket).
- Existing test files updated or removed accordingly (`memory_test.exs` versioning assertions, `build_memory_context*` association layers, `memory_actions_test.exs` extraction scope cases, `user_profile_clear_test.exs` version snapshots, RPC policy test rename).
- Standard gates: `mix precommit`, `MIX_ENV=test mix compile --warnings-as-errors`, SPA `npm run check` + `npm run test:unit` + `npm run format:check`.

## Phasing

- **Phase 1 (correctness):** section 1 plus extraction going local-only and the `set_memory` default flip. No migrations. Shippable alone (the promotion pipeline keeps running unchanged until Phase 2 removes it).
- **Phase 2 (simplification):** section 3 plus the curator change in section 2. One `mix ash.codegen` migration wave (pre-clean inactive rows, drop four tables, drop four columns, drop the `[conversation_id, last_accessed_at]` index, rebuild three unique indexes), the destroy policy bypass, the `RetractResource` worker, the distiller input change with promotion/merge/decay removal, cap enforcement, and the RPC/SPA rename.

One implementation plan covers both phases; work happens on a worktree branch because of the migration surface.

## Flagged follow-up (explicitly not in this change)

**Push-to-pull injection.** Shrink the ambient block toward profile + current-conversation memories and lean on `search_memories` (and later `super_brain_search`) for cross-conversation recall, potentially with a conversation-window query embedding instead of last-message-only. Deferred until v2 has landed and the Super Brain retrieval layer matures; revisit alongside the graph roadmap.

## Risks

- **Retrieval regression from removing associations:** mitigated by the eval gate; the layer contributed at most 3 memories per context build and its value was never demonstrated.
- **Hard delete is irreversible:** accepted explicitly. PubSub `memory_deleted` still fires so open UIs stay consistent; UI copy updated to say permanent.
- **The profile becomes the single ambient path to durability:** if the distiller misjudges, a durable fact does not reach ambient memory (it remains in local rows and in `search_memories` reach). Mitigated by the distiller's direct eval (6/6, extended with the new input-window case), the pending-notes fast lane, and explicit `set_memory` user-scope commands.
- **No time-based pruning remains:** local growth is bounded by the per-conversation cap and name-upsert dedup; user and agent buckets are small and explicitly curated. If an unforeseen growth vector appears, reintroduce pruning as an explicit, visible policy, not a silent background sweep.
