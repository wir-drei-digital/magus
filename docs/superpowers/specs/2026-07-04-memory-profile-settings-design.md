# Memory and Profile Settings View: Design

## Goal

A new "Memory" section in the SPA settings that gives users transparency into and control over their own memory: view their user-scope memories and distilled profile, delete individual memories, reset the profile, and globally enable or disable memory and the profile, with a per-workspace view filter.

## Context

- Builds on the memory-hardening branch / PR #13, which introduced the `UserProfile` resource and the profile feature.
- Memory data model: user-scope memories are bucketed by workspace (`workspace_id`, nil = the personal bucket). `UserProfile` is a singleton distilled document per `(user, workspace)` bucket, including the personal bucket.
- Existing backend: `User.global_memory_enabled` (boolean, default true) plus an `update_global_memory_setting` action already gate memory injection. `Config.profile_enabled?/0` currently reads a global env/config flag (`MAGUS_MEMORY_PROFILE` / `:memory_profile_enabled`).
- SPA: Svelte 5 (runes), settings live under `frontend/src/routes/settings/<section>/+page.svelte` with nav in `frontend/src/lib/components/shell/settings-nav.svelte`. Backend calls go through Ash RPC via ash_typescript (`frontend/src/lib/ash/ash_rpc.ts`, wrapped in `frontend/src/lib/ash/api.ts`). Global state in `frontend/src/lib/stores/session.svelte.ts`. Component library is bits-ui + custom CRUD components (`Section`, `ToggleSwitch`), Tailwind 4 (not DaisyUI). An agent-memory list/delete pattern already exists in the SPA to mirror.

## Locked decisions

1. **Scope:** user-scope memories + the profile only. Not agent-scope or local (per-conversation) memories.
2. **Control level:** view + delete for memories; view + reset for the profile. No inline editing of memory content or profile text.
3. **Toggles are global (per-user), not per-workspace:**
   - Memory: reuse `User.global_memory_enabled` (default on).
   - Profile: a new `User.profile_enabled` (default **off**, since the profile is still being validated).
4. **Remove the `MAGUS_MEMORY_PROFILE` env/config flag.** `profile_enabled?` becomes per-user and returns `user.profile_enabled`. Turning the profile on for everyone later is a default change or an admin-level setting, out of scope here.
5. **"Disable memory" stops both extraction and injection** (the privacy-respecting reading). Existing memories are preserved; the user deletes those separately. Today `global_memory_enabled` only gates injection, so extraction gets an added gate.
6. **Delete is a soft-delete** (`is_active = false`, the mechanism the system already uses to "forget"). The memory disappears from the UI and from all recall and is not recoverable through the UI; the row and version history are retained.
7. **Profile is per-workspace data; enable is global.** The workspace filter selects which bucket's profile document is viewed and reset. When memory is off, the profile toggle is disabled (there is nothing to distill from).
8. **Toggling off is non-destructive.** Turning memory or profile off stops recording/distilling and injecting, but preserves existing memories and profile documents (they become inert). Clearing content is explicit: delete individual memories, or Reset the profile.

## Backend changes

### User resource (`lib/magus/accounts/user.ex`)

- Add attribute `profile_enabled :boolean` (default `false`, `public? true`, `allow_nil? false`), sibling to `global_memory_enabled`.
- Add action `update_profile_setting` (accept `[:profile_enabled]`) with policy `authorize_if expr(id == ^actor(:id))`, mirroring `update_global_memory_setting`.
- Ensure both `update_global_memory_setting` and `update_profile_setting` are RPC-exposed (rpc_action entries in the Accounts domain's ash_typescript config).

### Profile gating (`lib/magus/agents/config.ex` and call sites)

- Replace `profile_enabled?/0` with `profile_enabled?(user)` returning `user.profile_enabled`. Remove the `MAGUS_MEMORY_PROFILE` / `:memory_profile_enabled` reads.
- Update the two call sites:
  - `Magus.Agents.Actions.ConsolidateMemories` distill step (runs per user): load `profile_enabled` for the user and gate the distill per user.
  - `Magus.Agents.Actions.BuildMemoryContext`: gate the profile load/injection on the user's `profile_enabled` (load the field on the actor or pass it through).
- This reworks the gating PR #13 introduced. Update the tests that set the env flag (`consolidate_memories_profile_test.exs`, the `build_memory_context` profile-injection test) to set `user.profile_enabled` instead. `DistillUserProfile.run/2` is called directly by the eval subject and is unaffected (the gate lives in the callers, not the action).

### Extraction gating (respect memory disable)

- Gate the turn-extraction path on the user's `global_memory_enabled`: when false, skip extraction so "disable memory" stops recording, not just injecting. Gate in the extraction change body (`Magus.Chat.Conversation.Changes.ExtractTurnMemories`, which already loads context), by loading the conversation owner and returning early when `global_memory_enabled` is false. Not the trigger `where` clause, which operates on the Conversation and cannot easily reach the user setting.

### Memory read + delete over RPC (`lib/magus/memory/memory_resource.ex` + domain)

- Expose `user_for_user` (list user-scope memories for the actor in a bucket) over RPC. The read policy already authorizes the owner (`user_id == actor(:id)`).
- Expose the soft-delete (`deactivate`) over RPC for the owner. Verify the update/destroy policy authorizes a real user-actor deactivating their own memory (the resource map indicates owner-based update/destroy; confirm and adjust if it is AI-agent-bypass only).

### UserProfile read + reset over RPC (`lib/magus/memory/user_profile.ex` + domain)

- Add the `AshTypescript.Resource` extension and expose `for_bucket` (read; owner policy already present) over RPC.
- Add a `clear` action (owner policy) that empties the document: set `document` to `""`, `token_estimate` to 0, clear `pending_notes`, and snapshot a version (so the reset is auditable). Expose over RPC. Chosen over destroy so the row and version history survive.

### API wrappers (`frontend/src/lib/ash/api.ts`)

- Thin, field-selected wrappers for: update memory setting, update profile setting, list user memories (by workspace bucket), deactivate memory, get profile (by bucket), reset (clear) profile. Follow the model-selection wrapper pattern.

## Frontend (SPA)

### Route + navigation

- Add `{ id: 'memory', label: 'Memory', icon: Brain }` to `settings-nav.svelte`, the label to settings `+layout.svelte`, and create `frontend/src/routes/settings/memory/+page.svelte`.

### Page layout

- **Toggles** (CRUD `ToggleSwitch`): Memory (`global_memory_enabled`) and Profile (`profile_enabled`). The Profile toggle is disabled when memory is off, with a short note ("Turn memory on to use profiles").
- **Workspace filter** (Select): Personal + the user's workspaces (from the session store). A view filter, not a toggle.
- **Memories list:** the selected bucket's user-scope memories, each row showing name, summary, kind, and last-updated, with a delete button (soft-delete). Mirror the existing agent-memory list/delete UI.
- **Profile card:** the selected bucket's distilled document, rendered read-only, with `last_distilled_at` and a Reset button (confirmation dialog).
- Loading skeletons and empty states ("No memories yet", "No profile yet: it is distilled from your memories overnight").

### State + data flow

- On mount: read the two toggle values from the current user; load memories and profile for the default bucket (personal).
- Toggle change: RPC update with optimistic local update; revert + toast on error (mirror the model-selection flow).
- Workspace filter change: refetch memories and profile for the new bucket.
- Delete memory: RPC deactivate, remove the row optimistically.
- Reset profile: confirm, RPC clear, empty the card.

## Error handling

- RPC errors surface as toasts; optimistic updates revert on failure. The existing 401-to-unauthenticated mapping covers the (unexpected) unauthorized case for own-data actions.

## Testing

- **Backend:**
  - Policy: a user can list and deactivate only their own memories; read and reset only their own profile.
  - Behavior: memory off stops both extraction and injection; profile off stops both distillation and injection; `profile_enabled` defaults false.
  - Action: `update_profile_setting`; profile `clear` (document emptied, version snapshotted).
- **SPA:**
  - Settings page: toggles call the correct RPC and reflect state; the profile toggle is disabled when memory is off; the workspace filter refetches; delete removes a row; reset clears the profile card. Follow the existing settings-page component-test pattern.

## Sequencing and dependency

- The profile half (profile toggle, per-user gating rework, profile card, reset) depends on PR #13's `UserProfile` and its profile gating. The memory half (memory toggle, list, delete, extraction gating) is independent of PR #13.
- Implementation branches off `main` after PR #13 merges (main will then have `UserProfile`), or off the memory-hardening branch if built before that merge.

## Out of scope (explicit)

- Per-workspace enable toggles (global only for v1; per-workspace is a clean later extension).
- Editing memory content or profile text.
- Agent-scope and local-scope memories in this view.
- A global admin "profile on for everyone" (revisit after the profile is validated).
