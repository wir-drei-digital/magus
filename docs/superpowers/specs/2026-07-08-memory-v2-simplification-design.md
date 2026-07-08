# Memory v2: Repair + Simplification Design

**Date:** 2026-07-08
**Status:** Approved direction (option B: repair + simplify), spec pending review

## Product framing

Memory is the lightweight layer that keeps an agent *relevant*: who the user is, what is going on in this conversation, and a small set of durable user facts. It is not a knowledge store. Topic-specific knowledge lives in Brains (and the Super Brain graph), and the distilled **user profile** is the primary user-level artifact. Episodic memory rows exist to feed the profile and to give conversations continuity, nothing more.

Consequences of this framing:

- The **local** scope (conversation) is the workhorse and the default destination for everything extracted.
- The **user** bucket is small and curated. It is fed only by deliberate paths (nightly promotion, explicit "remember this everywhere" commands), never by ambient per-turn extraction.
- Machinery that does not serve relevance (provenance tables, version history, association graphs, unused metadata) is removed rather than finished.

## Problems this fixes

1. **Workspace bug (reported):** user-scope memories created while working in a workspace end up in the Personal bucket. Root cause analysis (2026-07-08 deep dive): every current write path *does* propagate `workspace_id` correctly, but the bucket is inherited from `conversation.workspace_id`, and there is no server-side guardrail for user scope. `set_memory` falls back to `nil` silently when the tool context lacks the key (`lib/magus/agents/tools/memory/set_memory.ex:152`), and the `:create_user` action accepts `nil` without derivation or validation, while `:local` and `:agent` scopes both have `Derive*` guard changes. Pre-2026-04-25 rows were additionally backfilled to NULL by design.
2. **Scope over-assignment:** the agent puts too much into the user bucket. Two causes: `set_memory` defaults `scope` to `"user"` and its description promotes that default; the extraction prompt's bar for user scope is two vague lines ("general facts about the user"). Meanwhile a proper curated promotion gate (`PromoteMemoryCandidates`: pattern across >= 2 conversations, 0.85 similarity, LLM validation) already exists but is bypassed.
3. **Dead or half-wired machinery:** `memory_sources` has zero rows ever; `memory_versions` and `user_profile_versions` are written on every change and read nowhere; `changed_by` attribution always collapses to `:system`; `confidence` and `structured_data` are stored but never used; the Hebbian association layer (reinforcement writes on every context build, read-time decay, 1-hop expansion) is live but of unproven retrieval value and lets local memories from one conversation bleed into another via edges.

## Locked decisions

- Direction **B**: repair + structural simplification (user answer 2026-07-08).
- Remove the Hebbian association layer entirely.
- Remove `MemoryVersion` and `UserProfileVersion`; **hard deletes are acceptable** (user's words), so soft-delete goes too.
- Existing misfiled personal-bucket rows are left as-is (no reliable provenance to re-bucket them); users delete them via the settings UI.

## Design

### 1. Workspace correctness

**Tools derive the bucket from the conversation; the context value is only a fallback.**

- `set_memory`, `search_memories`, and `forget_memory`: for user-scope operations, resolve the bucket via `Magus.Memory.workspace_id_for_conversation(ctx.conversation_id)` when `conversation_id` is present in the tool context (the pattern `update_profile` already uses at `lib/magus/agents/tools/memory/update_profile.ex:44`). Fall back to `ctx.workspace_id` only when there is no conversation in context. The same derivation applies to the upsert lookup in `Magus.Agents.Tools.Memory.Helpers.find_memory_by_name/3`.
- Required context keys for user scope become `[:user_id, :conversation_id]`-or-`[:user_id, :workspace_id-key-present]`: concretely, `validate_context` keeps requiring `:user_id`, and the workspace resolution helper raises a tool error (returned as `{:ok, %{error: ...}}`) if neither `conversation_id` nor a `workspace_id` key is available, instead of silently writing to Personal.
- Extraction (`lib/magus/agents/actions/extract_turn_memories.ex:214`) already derives correctly; unchanged.
- No changes to conversation creation: SPA (`frontend/src/lib/stores/workbench.svelte.ts:376`) and classic both pass the active workspace already.

### 2. Scope discipline

**Extraction writes local only.**

- Remove `scope` from the extraction output schema and prompt in `extract_turn_memories.ex`. All extractions apply as local memories. Delete `apply_user_extraction/6`, `create_user_memory/6` (extraction-local helper), the `allow_global` downgrade branch, and the user-scope semantic-dedup path within extraction.
- The prompt is rewritten around: extract facts, decisions, and context relevant to *this conversation's continuity*; dedup against the listed existing memories (the existing user-bucket listing stays in the prompt as "already known about the user, do not re-extract"); `update_mode` merge/replace semantics stay; "keep extractions minimal" stays.

**The user bucket is fed by exactly two curated paths.**

- Nightly `PromoteMemoryCandidates` (unchanged: >= 2 conversations, 0.85 embedding similarity, LLM validation; `promote_to_user` preserves the workspace bucket).
- Profile distillation (`DistillUserProfile`, unchanged) plus `update_profile` pending notes.

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
| `confidence` | Never used for ranking or filtering; remove from tool params (`set_memory`), search-tool output, `USER_MEMORY_FIELDS` + the confidence line in the settings expand panel (`frontend/src/routes/settings/memory/+page.svelte`). |
| `structured_data` | Accepted, never read. Remove from tool params and action accepts. |

`kind` stays (visible in the UI, gives the distiller light structure). `last_accessed_at`, `summary_embedding`, `lock_version` stay.

**Soft delete becomes hard delete.**

- The `:deactivate` action is replaced by a custom `:destroy` action carrying `BroadcastMemoryEvent` (so `memory_deleted` PubSub still fires) and the Super Brain re-extract enqueue where applicable (graphs are disposable; brief staleness from deleted rows is acceptable and healed by the migration sweeper).
- All `is_active == true` filters drop out of the read actions. The three unique identities lose their `is_active` predicate and become partial-on-scope unique indexes: `[conversation_id, name] WHERE scope = 'local'`, `[user_id, workspace_id, name] (nils_distinct: false) WHERE scope = 'user'`, `[custom_agent_id, name] WHERE scope = 'agent'`.
- Callers updated: `ForgetMemory` tool, nightly decay in `ConsolidateMemories` (stale memories after 90 days unaccessed are now deleted, not deactivated), merge cleanup in `MergeMemories`, the `deactivate_user_memory` RPC becomes `destroy_user_memory` (SPA `deactivateUserMemory` wrapper and the settings-page delete follow; UI copy must say the deletion is permanent).
- `mix ash_typescript.codegen` regenerates `ash_rpc.ts` after the RPC change.

### 4. Unchanged (explicitly)

Watermark all-turns extraction with Oban retries; semantic dedup at extraction (0.9) for local; pgvector semantic search; context injection layers minus associations (key recency top-3 per scope + semantic top-5 per scope, 6KB cap, profile replaces the user key-layer when enabled); `touch_accessed` on semantic hits; 90-day decay clock; profile distillation, `pending_notes`, per-user `global_memory_enabled` / `profile_enabled` gating; workspace-bucket read filters; the memory settings UI structure (toggles, bucket filter, list, expand, profile card).

## Out of scope

- Re-bucketing existing personal-bucket rows (no provenance; manual deletion via UI).
- Conversation-creation UX around workspace context (wiring verified correct in SPA and classic).
- Any classic-workbench UI changes.
- Per-workspace memory toggles, admin profile flags (unchanged from the 2026-07-04 settings design).
- Brains / Super Brain changes (graphs remain derived and rebuildable).

## Verification

- **Eval-gated:** `mix magus.eval longmemeval --limit 18` before and after the Phase 2 removals; the 3/18 hardened baseline must not regress (this specifically watches the association-layer removal). `MIX_ENV=test mix magus.eval profile_distill` must hold 6/6.
- **New regression tests:**
  - user-scope `set_memory` in a workspace conversation lands in that workspace bucket even when the tool context omits `workspace_id` (pins the reported bug);
  - user-scope `set_memory` with neither `conversation_id` nor `workspace_id` in context returns a tool error, not a Personal-bucket write;
  - extraction never creates `scope: :user` rows;
  - hard-delete then re-create with the same name succeeds under the new unique indexes;
  - decay deletes (not deactivates) stale memories.
- Existing test files updated or removed accordingly (`memory_test.exs` versioning assertions, `build_memory_context*` association layers, `memory_actions_test.exs` extraction scope cases, `user_profile_clear_test.exs` version snapshots, RPC policy test rename).
- Standard gates: `mix precommit`, `MIX_ENV=test mix compile --warnings-as-errors`, SPA `npm run check` + `npm run test:unit` + `npm run format:check`.

## Phasing

- **Phase 1 (correctness):** section 1 + section 2. No migrations. Shippable alone.
- **Phase 2 (simplification):** section 3. One `mix ash.codegen` migration wave (drop three + one tables, drop three columns, rebuild three unique indexes) plus the RPC/SPA rename.

One implementation plan covers both phases; work happens on a worktree branch because of the migration surface.

## Risks

- **Retrieval regression from removing associations:** mitigated by the eval gate; the layer contributed at most 3 memories per context build and its value was never demonstrated.
- **Hard delete is irreversible:** accepted explicitly. PubSub `memory_deleted` still fires so open UIs stay consistent; UI copy updated to say permanent.
- **User bucket starves without direct extraction writes:** promotion requires cross-conversation repetition, so the bucket fills more slowly by design. The fast lane for durable user facts is the `update_profile` pending-notes path (the agent can queue a note in any turn; the nightly distiller folds it into the profile document), and explicit `set_memory` user-scope commands still work in one turn.
