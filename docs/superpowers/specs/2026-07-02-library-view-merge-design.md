# Library View: Merging the SPA Prompts and Skills Modes

Date: 2026-07-02
Status: Approved design, pending implementation plan

## Summary

The SPA currently ships Prompts and Skills as two near-mirror features: identical master-detail layouts, near-identical gallery/card components, and two parallel nav stores that already drift (prompts have favorites, tags, publish, use counts, and global search; skills have none of those). Both collections are individually small, so each mode feels empty.

This design merges the two modes into a single **Library** mode: one mixed card grid with type badges, one generic gallery/card/nav-store implementation parameterized by item kind, one nav rail, and one `New` entry point. Backend resources stay separate (`Magus.Library.Prompt`, `Magus.Skills.Skill`); the merge is a UI and navigation consolidation plus two targeted parity additions (skill favorites, skills in global search). Creation and editing of both types move into modals, and the prompt modal gains a user/system type dropdown.

This supersedes the "UI layer (SPA)" section of `2026-06-27-user-managed-skills-design.md` where that section describes a standalone `skills` mode mirroring `prompts`. Everything else in that spec (resource model, runtime flow, import, security) is unaffected.

## Goals

- One Library mode replaces the Prompts and Skills modes: fuller view, less nav sprawl.
- One generic gallery/card/nav-store implementation replaces the mirrored pair, so future improvements are made once.
- Uniform scope filters (All / Favorites / Shared / Personal) across both types, which requires skill favorites.
- Skills become findable in global search.
- Create and edit flows for both types live in modals; detail routes become pure readers.

## Non-goals

- No backend resource merge. Prompt and Skill remain separate resources with separate detail views; they differ fundamentally in consumption (user inserts a prompt; the agent loads a skill).
- No tags on skills in v1. The Tags rail group stays prompt-only.
- Built-in skills (`priv/skills` registry) do not appear in the Library in v1; they remain visible only in the agent editor's pre-loaded-skills picker.
- No changes to chat-side consumption: the composer insert-prompt dialog, the right-rail prompts panel, system-prompt activation, use counts, the `?skill=` deeplink, and `startSkillConversation` are all unchanged.
- No public-library/publish changes; prompts keep publish/unpublish as-is, skills gain nothing there.

## Key decisions (from brainstorming)

1. **One mixed grid.** A single card grid mixing both types, with type badges on cards and a type filter (All / Prompts / Skills) in the toolbar. Chosen over per-type sections or tabs because small collections pooled together read as one full library.
2. **Parity scope: favorites + search.** Skills gain favorites and global-search indexing so the shared scope filters and search behave uniformly. Tags on skills are deferred.
3. **No built-ins in v1.** The Library shows only user/workspace prompts and skills.
4. **One `New` dropdown** in the nav pane: New prompt, New skill, Import skill.
5. **Modals for create and edit** of both types. Detail pages become pure readers with an Edit button. The prompt modal includes a user/system type dropdown.
6. **Unified route tree.** A new `/library` route tree with generic components replaces the `/prompts` and `/skills` trees; old URLs redirect. Chosen over a thin composition layer over the existing pieces, which would have left three surfaces to maintain.

## Design

### IA and navigation

- Mode strip (`frontend/src/lib/components/shell/mode-strip.svelte`): one `library` entry replaces the `prompts` and `skills` entries, positioned where Prompts sits today (Chat, Brain, Files, Library, Agents).
- `MODE_HOME`: `library` maps to `/library`. Route-to-mode inference updated for `/library/*`. The `WorkbenchMode` TS union drops `prompts`/`skills` and gains `library`.
- Backend `Magus.Workbench.TabSession.mode` `one_of` gains `:library` while keeping `:prompts` and `:skills` valid so saved sessions do not break; the SPA maps both legacy values to `library` on restore. No data migration. Regenerate the Ash snapshot via `mix ash.codegen` (DB migration only if a check constraint exists).
- Nav pane (`frontend/src/lib/components/shell/nav-pane.svelte`): in `library` mode the primary action is a single `New` dropdown with three entries: New prompt (prompt modal), New skill (skill modal), Import skill (existing zip import dialog). The rail is the new `LibraryNav`.

### Routes

- `/library/+layout.svelte` owns the merged gallery using the existing master-detail pattern: full-width grid, narrowing to a ~40% master rail when a reader is open. `/library/+page.svelte` stays intentionally empty, same as the current pattern.
- Readers: `/library/prompts/[promptId]/+page.svelte` and `/library/skills/[skillId]/+page.svelte`. Pure readers; the Edit button opens the corresponding modal prefilled.
- Redirects (client-side, since the SPA is adapter-static):
  - `/prompts` → `/library?type=prompts`; `/skills` → `/library?type=skills`
  - `/prompts/[id]` → `/library/prompts/[id]`; `/skills/[id]` → `/library/skills/[id]`
  - `/skills/new` → `/library` with the skill modal open
  - `?edit=true` on a detail deep link opens the modal over the reader instead of an inline form
- URL params on `/library`: `?type=` (all/prompts/skills), `?scope=` (all/favorites/shared/personal), `?tag=` (prompt tags). Search stays client-side state, as today.

### Gallery and cards (generic components)

- `library-gallery.svelte` + `library-card.svelte` replace `prompt-gallery`, `prompt-card`, `skill-gallery`, `skill-card`.
- Items are a discriminated union in TS: `LibraryItem = { kind: 'prompt', ... } | { kind: 'skill', ... }` built from the existing `PromptSummary` and `SkillSummary` RPC types.
- Toolbar: client-side search over name/description/content(prompt)/body(skill); segmented type filter All / Prompts / Skills; sort Most used / A-Z. Skills carry no use count and sort as 0 under Most used.
- Card: shared shell (icon, type badge, name, description, favorite star for both kinds) with kind-specific footers: tag chips and use count for prompts; "Runnable in sandbox" badge (from `hasExecutableBundle`) for skills.
- Empty states and the card grid (`auto-fill minmax`) carry over from the existing galleries.

### Nav rail and store

- One `library-nav.svelte.ts` store replaces `prompts-nav.svelte.ts` and `skills-nav.svelte.ts`. It loads both types via the existing RPCs (`myPrompts`, `myFavoritePrompts`, `workspacePrompts`, `mySkills`, `workspaceSkills`, plus the new skill-favorite reads) and exposes combined partitions All / Favorites / Shared / Personal with counts spanning both kinds. Keeps the `load(workspaceId, force)` / `refresh()` / load-key dedup shape of the stores it replaces. The `importOpen` flag moves here.
- `library-nav.svelte` (shell rail): a "Library" group with the four scope rows and count badges driving `?scope=`, followed by the existing "Tags" group (prompt tags only). Selecting a tag filters the grid to tagged prompts; skills are hidden while a tag filter is active.

### Create and edit modals

- **Prompt form modal**: one dialog for create and edit, grown from the prompt path of `new-resource-dialog.svelte` (whose `prompt` kind it replaces; the dialog keeps its other kinds). Fields as the current inline edit form, plus a **type dropdown (user/system)**. Edit opens it prefilled from the reader.
- **Skill form modal**: new dialog replacing both the `/skills/new` route form and the inline detail edit. Same fields and validation as today: `name` (`^[a-z0-9-]{1,64}$`), `displayName`, `description`, markdown `body`, `requestedTools`, and the artifacts panel (`fileManifest` upload/replace/remove). Wide, scrollable dialog since the form is large.
- **Import skill**: the existing `skill-import-dialog.svelte` unchanged, triggered from the `New` dropdown.
- Modal save errors render inline in the dialog, as the current forms do.

### Backend: skill favorites

Mirror `Magus.Library.PromptFavorite` (unique identity `[:user_id, :prompt_id]`) in the Skills domain:

- `Magus.Skills.SkillFavorite`: `user_id`, `skill_id`, unique identity `[:user_id, :skill_id]`, user-scoped policies (a user manages only their own favorites; favoriting requires read access to the skill).
- `is_favorited` calculation on `Skill` for the actor.
- Domain code-interface + RPC actions mirroring the prompt naming: `favoriteSkill`, `unfavoriteSkill`, `mySkillFavorites`.
- `mix ash.codegen` migration; `mix ash_typescript.codegen` for the TS client.

### Backend: skills in global search

- Add a skill searcher to the `Magus.Search` orchestrator (the parallel, policy-scoped search behind `lib/magus_web/rpc/search_controller.ex`), matching name, display name, description, and body. Policy scoping comes from the existing `workspace_scoped_policies` read policies on `Skill`.
- `'skill'` joins the controller's `types` param and the SPA `SearchResultType` union (`frontend/src/lib/ash/api.ts`). Skill results link to `/library/skills/[id]`.

### Cleanup (deleted by this work)

- Routes: `frontend/src/routes/prompts/*` and `frontend/src/routes/skills/*` reduced to redirect stubs.
- Components: `prompt-gallery.svelte`, `prompt-card.svelte`, `skill-gallery.svelte`, `skill-card.svelte`, shell rails `prompts-nav.svelte`, `skills-nav.svelte`.
- Stores: `prompts-nav.svelte.ts`, `skills-nav.svelte.ts` (and `skills-nav.test.ts`, superseded by the `library-nav` test).

## Error handling

- Legacy mode values (`:prompts`/`:skills`) in saved tab sessions map to `library` on restore; unknown routes under `/prompts` and `/skills` fall through to the `/library` redirect.
- Modal save failures stay in the dialog with inline errors; the reader below remains consistent (no optimistic navigation).
- Favorite toggle failures revert the optimistic star state, matching the current prompt behavior.
- Search: per-type failures in `Magus.Search` already degrade gracefully (the orchestrator returns partial results); the skill searcher inherits that.

## Testing

- **Store unit test**: `library-nav` partitions and counts across mixed prompt/skill fixtures (replaces `skills-nav.test.ts`).
- **Route tests**: route-to-mode inference for `/library/*`; redirect behavior for the legacy URLs.
- **Backend**: `SkillFavorite` policy tests (own-favorites only, read-access requirement, unique identity); search returns accessible skills and excludes inaccessible ones.
- **Frontend structural tests**: data-* hooks and counts only, no label/copy/CSS assertions, per project testing conventions.

## Open questions (resolved in the plan, none blocking)

- Exact redirect mechanics in adapter-static SvelteKit (`+page.ts` load redirects vs a client-side guard) and whether `/skills/new` can reliably open the modal post-redirect.
- Default sort for the mixed grid (keep the prompts default vs A-Z).
- Where the Library label is localized (the SPA's i18n mechanism; German informal per project convention).
- Whether `startSkillConversation`'s onboarding deep links need a Library-side "open in chat" affordance on the skill reader (nice-to-have, not required).

## Affected and new modules (indicative)

New:

- `frontend/src/routes/library/` (layout, page, `prompts/[promptId]`, `skills/[skillId]`, `components/library-gallery.svelte`, `components/library-card.svelte`).
- `frontend/src/lib/stores/library-nav.svelte.ts` (+ test), `frontend/src/lib/components/shell/library-nav.svelte`.
- `frontend/src/lib/components/shell/prompt-form-dialog.svelte`, `skill-form-dialog.svelte` (names indicative).
- `lib/magus/skills/skill_favorite.ex`.

Changed:

- `frontend/src/lib/components/shell/mode-strip.svelte`, `nav-pane.svelte`, `new-resource-dialog.svelte`.
- `frontend/src/lib/ash/api.ts` (regenerated + `SearchResultType`).
- `lib/magus/workbench/tab_session.ex` (`:library` in `mode` `one_of`).
- `lib/magus/skills/skills.ex` (favorite actions, RPC exposure), `lib/magus/skills/skill.ex` (`is_favorited`).
- `Magus.Search` orchestrator (+ skill searcher) and `lib/magus_web/rpc/search_controller.ex` types.

Removed: see Cleanup.
