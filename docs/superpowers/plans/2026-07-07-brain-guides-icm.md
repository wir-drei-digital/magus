# Brain Guides (ICM) + Page-Model Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn brains into an Interpretable Context Methodology space: an agent-maintained per-brain Guide (constitution + section guides + type templates) that loads just-in-time, plus a page-model cleanup that collapses `kind` to `:page`/`:template`, makes tasks universal (collapsible board on every page), and removes the plan/spec coupling.

**Architecture:** Two phases in one worktree. Phase A is mostly deletion + un-gating (leaves the tree green and shippable on its own). Phase B adds the Guide cascade (a `instructions` field on the brain, `instructions:`/`type:` frontmatter on pages, `:template` pages), injects it via `BrainContext`, exposes conversational CRUD through a new `brain_guide` tool, teaches it in the `brain_management` skill, and lints deviations into curation candidates. UI work is SPA-only.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, Jido actions, Phoenix; Svelte/SvelteKit SPA (`frontend/`); pgvector; AshTypescript RPC codegen.

**Reference spec:** `docs/superpowers/specs/2026-07-07-brain-guides-icm.md`

## Global Constraints

- **Never `mix ash.reset`.** Schema changes go through `mix ash.codegen` + `mix ash.migrate` only.
- **Ash conventions:** call resources through domain code interfaces, not `Ash.read/4`. Pass a real `actor:`; do not use `authorize?: false` in app code. Custom changes/calcs live in `lib/magus/<domain>/<resource>/changes|calculations/`.
- **Jido tool schema gotcha:** nullable fields MUST be `{:or, [<type>, nil]}` (a bare `type` with `default: nil` silently makes `run/2` unreachable). Enums are `{:in, [...]}`, lists `{:list, :string}`.
- **Warnings-as-errors:** CI compiles with `--warnings-as-errors` (per-edit hooks do NOT). Before any commit that touches Elixir, run `MIX_ENV=test mix compile --warnings-as-errors`.
- **Worktree test invocation:** `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. The worktree has its own `_build` and symlinked `deps` + `frontend/node_modules` + `.env`.
- **Shared test DB has leaked rows.** Scope every count/emptiness assertion to rows you seeded; never assert on global table counts.
- **SPA only.** Do not modify the classic LiveView brain UI. Backend attribute changes are shared and keep it compiling.
- **No em dashes** in any written content (code comments, docs, skill copy). Use colons, periods, parentheses.
- **Commits:** scoped (`git commit -m "..." -- <paths>`), Conventional-Commit style, end the message body with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Commit after each task's tests pass.
- **No backwards compatibility for plans/specs** (no relevant prod data): delete outright, no data migration.

---

# Phase A: Page-model consolidation

Order matters so the tree keeps compiling: remove dependents (HTTP, domain fns, actions, calc) before shrinking the `kind` enum, then migrate, then frontend.

### Task A1: Remove the v2 plans HTTP surface

**Files:**
- Delete: `lib/magus_web/api/v2/plans_controller.ex`
- Modify: `lib/magus_web/core_router.ex:509-518` (remove the 6 plan/spec routes)
- Delete: `test/magus_web/api/v2/plan_lifecycle_test.exs`

- [ ] **Step 1: Delete the controller and its test, remove the routes.** Remove the six routes at core_router.ex:509-518 (`get "/plans/:id"`, `post "/plans/:id/deliver"`, `post "/plans/:id/undeliver"`, `post "/plans/:id/spec"`, `get "/brains/:brain_id/stranded"`, `get "/specs/:id/plans"`). Delete `plans_controller.ex` and `plan_lifecycle_test.exs`.
- [ ] **Step 2: Verify compile.** Run: `MIX_ENV=test mix compile --warnings-as-errors`. Expected: compiles (no references to the removed controller remain).
- [ ] **Step 3: Verify no dangling route refs.** Run: `grep -rn "PlansController\|/plans/\|stranded\|/specs/" lib/magus_web/`. Expected: no matches.
- [ ] **Step 4: Commit.** `git commit -m "refactor(brain): remove v2 plans/specs HTTP endpoints" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus_web/api/v2/plans_controller.ex lib/magus_web/core_router.ex test/magus_web/api/v2/plan_lifecycle_test.exs`

### Task A2: Remove plan/spec domain functions

**Files:**
- Modify: `lib/magus/brain/brain.ex:103-107` (remove `set_page_spec`, `plans_for_spec`, `mark_page_delivered`, `undeliver_page`, `stranded_plans` `define`s)

**Interfaces:**
- Produces: none. Consumers were A1 (removed) and tests removed in A3/A4.

- [ ] **Step 1: Remove the domain interface definitions** at brain.ex:103-107 for the plan/spec actions listed above.
- [ ] **Step 2: Verify compile.** Run: `MIX_ENV=test mix compile --warnings-as-errors`. Expected: compiles (the underlying actions still exist until A3/A4).
- [ ] **Step 3: Commit.** `git commit -m "refactor(brain): drop plan/spec domain interfaces" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/brain.ex`

### Task A3: Remove plan/spec read actions, lifecycle calc, and stranded filter

**Files:**
- Modify: `lib/magus/brain/page.ex` (remove read `:plans_for_spec` 336-346, read `:stranded_plans` 348-368, calculation `:lifecycle` 691-693)
- Delete: `lib/magus/brain/page/calculations/lifecycle.ex`
- Delete: `lib/magus/brain/page/preparations/filter_done_plans.ex`
- Delete: `test/magus/brain/page_lifecycle_test.exs`

- [ ] **Step 1: Remove the two read actions, the `:lifecycle` calculation declaration, and delete the lifecycle + filter_done_plans modules and the lifecycle test.** Also remove the `child_plan_pages: [:lifecycle]` load referenced around page.ex:30 if present.
- [ ] **Step 2: Verify compile.** Run: `MIX_ENV=test mix compile --warnings-as-errors`. Expected: compiles.
- [ ] **Step 3: Commit.** `git commit -m "refactor(brain): remove plan lifecycle calc and stranded-plan reads" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/page.ex lib/magus/brain/page/calculations/lifecycle.ex lib/magus/brain/page/preparations/filter_done_plans.ex test/magus/brain/page_lifecycle_test.exs`

### Task A4: Remove plan/spec actions, attributes, relationships; shrink `kind`

**Files:**
- Modify: `lib/magus/brain/page.ex`:
  - Actions: remove `:set_kind` (211-216), `:set_spec` (218-223), `:mark_delivered` (225-236), `:undeliver` (238-245)
  - Attributes: remove `:delivered_at` (620-628), `:delivery_ref` (630-633); change `:kind` constraint (583) to `one_of: [:page, :template]`
  - Relationships: remove `:spec_page` (643-649), `:implementing_plans` (657-658), `:child_plan_pages` (667-670); keep `:tasks` (661) but update its doc comment to drop ":plan page" wording
- Delete: `test/magus/brain/page_kind_test.exs`, `test/magus/brain/page_spec_link_test.exs`
- Modify: `test/magus/agents/sub_agent/resumer_test.exs` (remove only the stranded/plan-delivery assertions; keep AgentRun `mark_delivered` coverage which is unrelated)

**Interfaces:**
- Produces: `Page.kind` now `∈ {:page, :template}`, default `:page`.

- [ ] **Step 1: Make the removals above.** Do NOT touch `lib/magus/agents/sub_agent/resumer.ex:130` (that `mark_delivered` is on AgentRun, not Page).
- [ ] **Step 2: Verify compile.** Run: `MIX_ENV=test mix compile --warnings-as-errors`. Expected: compiles.
- [ ] **Step 3: Grep for residual references.** Run: `grep -rn ":plan\b\|:spec\b\|spec_page\|delivered_at\|delivery_ref\|implementing_plans\|child_plan_pages\|mark_delivered\|set_kind\|set_spec" lib/magus/brain lib/magus/plan`. Expected: no matches except the AgentRun `mark_delivered` path (agents/), which is out of scope. Fix any stragglers.
- [ ] **Step 4: Commit.** `git commit -m "refactor(brain): collapse page kind to :page/:template, drop plan/spec machinery" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/page.ex test/magus/brain/page_kind_test.exs test/magus/brain/page_spec_link_test.exs test/magus/agents/sub_agent/resumer_test.exs`

### Task A5: Generate and run the schema migration

**Files:**
- Create: `priv/repo/migrations/*_collapse_page_kind.exs` (generated)
- Modify: `priv/resource_snapshots/**` (generated)

- [ ] **Step 1: Generate the migration.** Run: `mix ash.codegen collapse_page_kind`. Inspect the generated migration: it should drop `delivered_at`, `delivery_ref`, and the `spec_page_id` FK column, and adjust any `kind` check constraint to `('page','template')`.
- [ ] **Step 2: Run it.** Run: `mix ash.migrate`. Expected: migration applies cleanly.
- [ ] **Step 3: Verify test DB.** Run: `MIX_ENV=test mix ash.migrate`. Expected: applies.
- [ ] **Step 4: Commit.** `git commit -m "feat(brain): migration to collapse page kind + drop delivery/spec columns" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- priv/repo/migrations priv/resource_snapshots`

### Task A6: Backend green gate

- [ ] **Step 1: Run the brain + plan test suites.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/brain test/magus/plan`. Expected: pass (dead tests already removed).
- [ ] **Step 2: Full compile gate.** Run: `MIX_ENV=test mix compile --warnings-as-errors`. Expected: clean.
- [ ] **Step 3: No commit** (verification only). If failures, fix in the owning task's file and amend that task's commit.

### Task A7: Rename plan-board to task-board and un-gate it

**Files:**
- Rename: `frontend/src/lib/components/plan/plan-board.svelte` -> `.../task-board.svelte` (and update the component name/imports)
- Modify: `frontend/src/routes/brain/page/[pageId]/+page.svelte:522-526` (remove the `kind === 'plan'` gate)

**Interfaces:**
- Consumes: `TaskBoard` takes `brainPageId` (unchanged prop).

- [ ] **Step 1: Rename the component** `plan-board.svelte` to `task-board.svelte`, rename the exported component to `TaskBoard`, and update all imports (grep `plan-board` / `PlanBoard`).
- [ ] **Step 2: Un-gate rendering.** Replace the `{#if pageData.kind === 'plan'}` block at +page.svelte:522-526 so the board renders for content pages: gate on `pageData.kind === 'page'` (never for `:template`).
- [ ] **Step 3: Verify build.** Run: `cd frontend && npm run build`. Expected: builds.
- [ ] **Step 4: Commit.** `git commit -m "feat(brain/spa): rename plan-board to task-board, show on all content pages" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- frontend/src/lib/components/plan frontend/src/routes/brain/page`

### Task A8: Collapsible bottom-bar layout + collapse state

**Files:**
- Modify: `frontend/src/routes/brain/page/[pageId]/+page.svelte` (wrap `TaskBoard` in a collapsible bottom bar)
- Create: `frontend/src/lib/components/brain/task-bottom-bar.svelte` (collapsible container: header row with a count + chevron toggle, body renders `TaskBoard`)

**Interfaces:**
- Produces: `TaskBottomBar` props `{ brainPageId: string }`; persists collapsed state in `localStorage` keyed `brain-taskbar-collapsed:<brainId>` (default collapsed when the page has zero tasks, expanded otherwise).

- [ ] **Step 1: Write a component test** `frontend/tests/task-bottom-bar.spec.ts` asserting: the bar renders on a content page, toggling the chevron hides/shows the board, and the collapsed state round-trips through `localStorage`. (Follow the existing Playwright/vitest pattern used by the former `plan-board.spec.ts`.)
- [ ] **Step 2: Run it, expect fail.** Run: `cd frontend && npm test -- task-bottom-bar`. Expected: FAIL (component not created).
- [ ] **Step 3: Implement `task-bottom-bar.svelte`** and use it in `+page.svelte` in place of the raw board div. Collapse state via `localStorage`; a compact header (task count + chevron).
- [ ] **Step 4: Run it, expect pass.** Run: `cd frontend && npm test -- task-bottom-bar`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain/spa): collapsible task bottom-bar on every brain page" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- frontend/src/lib/components/brain/task-bottom-bar.svelte frontend/src/routes/brain/page frontend/tests/task-bottom-bar.spec.ts`

### Task A9: Remove dead frontend plan/spec logic + regenerate types

**Files:**
- Modify: `frontend/src/lib/components/plan/plan-tree-store.svelte.ts` (remove `kind === 'plan' || kind === 'spec'` filtering ~73, `specPageId` checks ~115, and `isStranded` ~51-53)
- Modify: `frontend/src/lib/components/shell/brain-nav.svelte:42` (`kind: 'page' | 'template'`)
- Regenerate: `frontend/src/lib/ash/ash_types.ts`, `frontend/src/lib/ash/ash_rpc.ts` (drop `specPageId`/`deliveredAt`/`deliveryRef`, `kind` union shrinks)
- Delete: `frontend/tests/plan-board.spec.ts` (superseded by A8)

- [ ] **Step 1: Regenerate RPC/types.** Run the project's AshTypescript codegen (grep `package.json` / mix aliases for the `ash.typescript` / `rpc` gen command; e.g. `mix ash_typescript.codegen`). Confirm `kind` is now `'page' | 'template'` and the plan/spec fields are gone.
- [ ] **Step 2: Remove the dead store/nav logic** and delete `plan-board.spec.ts`. Fix any type errors surfaced by the shrunk `kind` union.
- [ ] **Step 3: Verify typecheck + build + tests.** Run: `cd frontend && npm run check && npm run build && npm test`. Expected: clean.
- [ ] **Step 4: Commit.** `git commit -m "refactor(brain/spa): remove dead plan/spec UI logic, regen ash types" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- frontend/src/lib frontend/tests/plan-board.spec.ts`

---

# Phase B: Brain Guides

### Task B1: Brain `instructions` field + `set_instructions` action

**Files:**
- Modify: `lib/magus/brain/brain_resource.ex` (attribute + accepts + action)
- Test: `test/magus/brain/brain_instructions_test.exs`

**Interfaces:**
- Produces: `BrainResource` attribute `:instructions` (string, nullable, public); action `:set_instructions` accepting `[:instructions]`; domain interface `Magus.Brain.set_brain_instructions/2` (add a `define` in brain.ex).

- [ ] **Step 1: Write the failing test.**

```elixir
# test/magus/brain/brain_instructions_test.exs
defmodule Magus.Brain.BrainInstructionsTest do
  use Magus.DataCase, async: true

  test "set_instructions updates only the constitution" do
    user = Magus.AccountsFixtures.user_fixture()
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Research"}, actor: user)
    {:ok, updated} = Magus.Brain.set_brain_instructions(brain, %{instructions: "Atomic pages only."}, actor: user)
    assert updated.instructions == "Atomic pages only."
  end
end
```

- [ ] **Step 2: Run it, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/brain/brain_instructions_test.exs`. Expected: FAIL (unknown action / interface).
- [ ] **Step 3: Implement.** In `brain_resource.ex`: add `attribute :instructions, :string, public?: true`; add `:instructions` to `create`/`update` accepts; add:

```elixir
update :set_instructions do
  accept [:instructions]
end
```

In `brain.ex` add `define :set_brain_instructions, action: :set_instructions`.

- [ ] **Step 4: Codegen + migrate.** Run: `mix ash.codegen add_brain_instructions && mix ash.migrate && MIX_ENV=test mix ash.migrate`.
- [ ] **Step 5: Run test, expect pass.** Same command as Step 2. Expected: PASS.
- [ ] **Step 6: Commit.** `git commit -m "feat(brain): add agent-maintained instructions (constitution) to brains" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/brain_resource.ex lib/magus/brain/brain.ex test/magus/brain/brain_instructions_test.exs priv/repo/migrations priv/resource_snapshots`

### Task B2: Frontmatter `instructions` + `type` keys

**Files:**
- Modify: `lib/magus/brain/frontmatter.ex` (`@known_keys` line 30, `normalize_known_keys/1` lines 125-130, add `normalize_text/1`)
- Test: `test/magus/brain/frontmatter_test.exs` (add cases; create if absent)

**Interfaces:**
- Produces: parsed frontmatter maps carry normalized `"instructions"` (trimmed string or absent) and `"type"` (trimmed string or absent).

- [ ] **Step 1: Write failing tests** asserting `Frontmatter.parse("---\ntype: Paper\ninstructions: One paper per page.\n---\n# X\n")` yields `%{"type" => "Paper", "instructions" => "One paper per page."}`, and that a blank `type:` is dropped.
- [ ] **Step 2: Run, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/brain/frontmatter_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.** Extend `@known_keys` to `~w(icon tags aliases created modified instructions type)`. Add to `normalize_known_keys/1`:

```elixir
key == "instructions" -> put_if_present(acc, key, normalize_text(v))
key == "type" -> put_if_present(acc, key, normalize_text(v))
```

Add:

```elixir
defp normalize_text(v) when is_binary(v) do
  case String.trim(v) do
    "" -> nil
    t -> t
  end
end
defp normalize_text(v) when is_number(v) or is_atom(v), do: normalize_text(to_string(v))
defp normalize_text(_), do: nil
```

- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): normalize type + instructions frontmatter keys" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/frontmatter.ex test/magus/brain/frontmatter_test.exs`

### Task B3: Exclude `:template` pages from listing and graph extraction

**Files:**
- Modify: `lib/magus/brain/page.ex` (`read :for_brain` at 284: filter `kind != :template`; add `read :templates_for_brain` filtering `kind == :template`)
- Modify: `lib/magus/brain/page/changes/enqueue_super_brain_extraction.ex` (skip when `kind == :template`)
- Verify: the extraction worker strips frontmatter before the LLM call (reuse `Magus.Brain.Frontmatter.parse/1` or `Chunker` strip). Add stripping if missing.
- Test: `test/magus/brain/page_template_kind_test.exs`

**Interfaces:**
- Produces: `Magus.Brain.templates_for_brain/2` returning `:template` pages; `for_brain`/`list_pages` exclude templates.

- [ ] **Step 1: Write failing tests:** creating a `:template` page then `list_pages` does not include it; `templates_for_brain` returns it; `EnqueueSuperBrainExtraction` does not enqueue for a `:template` page (assert via `Oban` job absence scoped to that page id).
- [ ] **Step 2: Run, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/brain/page_template_kind_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement** the `for_brain` filter, the `templates_for_brain` read + domain `define`, the extraction skip, and frontmatter stripping in the extraction worker if absent.
- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): treat :template pages as meta (excluded from listing + extraction)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/brain/page.ex lib/magus/brain/page/changes/enqueue_super_brain_extraction.ex lib/magus/brain/brain.ex test/magus/brain/page_template_kind_test.exs`

### Task B4: Inject the Guide into agent context

**Files:**
- Modify: `lib/magus/agents/context/brain_context.ex` (`compose/6`, add `### Brain Guide`)
- Test: `test/magus/agents/context/brain_context_test.exs` (add cases)

**Interfaces:**
- Consumes: `Hierarchy.ancestor_pages/2`; `brain.instructions`; each page's cached `frontmatter["instructions"]`; `Magus.Brain.templates_for_brain/2`.
- Produces: the composed system-prompt string contains a `### Brain Guide` block when a constitution, any inherited section guide, or any type exists.

- [ ] **Step 1: Write failing tests:** given a brain with `instructions` and an ancestor page whose frontmatter has `instructions:`, `BrainContext.build/3` output contains the constitution text, the inherited section guide (ancestors ordered root-to-current), and a compact `Types:` line listing template titles. Given none of those, no `### Brain Guide` header appears.
- [ ] **Step 2: Run, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/context/brain_context_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement `build_guide_section/…`** and insert it into the `sections` list (brain_context.ex:136-154), after the brain header and before `### Current Page Body`. Load the ancestor chain's cached `frontmatter` (query `[:frontmatter]` for the ancestor ids if `pages` lacks it). Compose: constitution (verbatim, soft-cap ~200 lines with a truncation note), inherited section guides (root-to-current, nearest last), and a one-line-per-type index from `templates_for_brain`. Omit the whole block when all three are empty. Also surface the active page's `type` in the frontmatter line (186-196).
- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): inject the brain Guide (constitution + section guides + types) into agent context" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/context/brain_context.ex test/magus/agents/context/brain_context_test.exs`

### Task B5: Scaffold the `brain_guide` tool with `get_guide`

**Files:**
- Create: `lib/magus/agents/tools/brain/brain_guide.ex`
- Register: wherever `EditBrain`/`ReadBrain` are registered as agent tools (grep `Magus.Agents.Tools.Brain.EditBrain`)
- Test: `test/magus/agents/tools/brain/brain_guide_test.exs`

**Interfaces:**
- Produces: `Magus.Agents.Tools.Brain.BrainGuide` (`use Jido.Action`), `display_name/0`, `summarize_output/1`, `run/2`; param `action` `{:in, ["get_guide","set_brain_guide","set_page_guide","define_type","set_page_type"]}`; nullable params as `{:or, [:string, nil]}`. `run/2` validates context `[:user_id, :user]` and dispatches (mirror `EditBrain.run/2` + `dispatch/4`). This task implements only `get_guide`.

- [ ] **Step 1: Write a failing test** for `get_guide` returning `%{constitution: ..., section_guides: [...], type_template: ...}` for a page in a brain with a constitution.
- [ ] **Step 2: Run, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/brain/brain_guide_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement the tool skeleton** (mirror `EditBrain`: `use Jido.Action` with schema, `@valid_actions`, `run/2` -> `dispatch/4`, `get_param/2`, `validate_context/2`). Implement `dispatch("get_guide", …)` reusing the same Guide assembly helper as B4 (extract a shared `Magus.Brain.Guide` module if cleaner). Register the tool alongside the other brain tools.
- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): brain_guide tool scaffold + get_guide" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/brain_guide.ex test/magus/agents/tools/brain/brain_guide_test.exs`

### Task B6: `brain_guide` set_brain_guide

**Files:** Modify `brain_guide.ex`; extend `brain_guide_test.exs`.

**Interfaces:** `dispatch("set_brain_guide", %{brain_id, instructions}, …)` -> `Magus.Brain.set_brain_instructions/2` with the actor; returns `%{action: "set_brain_guide", brain_id: …}`.

- [ ] **Step 1: Failing test** that `set_brain_guide` writes `brain.instructions` and a subsequent `get_guide` returns it.
- [ ] **Step 2: Run, expect fail.** Command as B5.
- [ ] **Step 3: Implement** the dispatch clause; resolve `brain_id` (accept id/slug/title using the existing resolver used by the other brain tools).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): brain_guide set_brain_guide (constitution)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/brain_guide.ex test/magus/agents/tools/brain/brain_guide_test.exs`

### Task B7: `brain_guide` set_page_guide (section guide)

**Files:** Modify `brain_guide.ex`; extend test.

**Interfaces:** `dispatch("set_page_guide", %{page_id|page_title, instructions}, …)` sets the page's `instructions:` frontmatter by reading the body, upserting the key via `Frontmatter.parse` + `Frontmatter.dump`, and writing through `edit_brain`'s existing `update_body` path (reuse the shared body-write helper the other brain tools use, preserving `base_version`).

- [ ] **Step 1: Failing test:** `set_page_guide` on a page makes its frontmatter carry `instructions:`, and `get_guide` for a child page inherits it.
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement.** Merge the key into existing frontmatter (do not clobber `type`/`tags`); write via `update_body` with the current `base_version`.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): brain_guide set_page_guide (subtree section guide)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/brain_guide.ex test/magus/agents/tools/brain/brain_guide_test.exs`

### Task B8: `brain_guide` define_type (template page)

**Files:** Modify `brain_guide.ex`; extend test.

**Interfaces:** `dispatch("define_type", %{brain_id, type_name, template_body, description}, …)` creates or updates a `:template` page titled `type_name` (body = `template_body`, optional `description` stored as the template page's frontmatter `description` or first line). Returns `%{action: "define_type", type: type_name, page_id: …}`.

- [ ] **Step 1: Failing test:** `define_type` creates a `:template` page listed by `templates_for_brain` and excluded from `list_pages`; calling it again updates the same page.
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement.** Create via the page `:create` action with `kind: :template` (add `kind` to the create accept if not already accepted), then write the body via `update_body`; upsert by title within the brain.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): brain_guide define_type (per-type template pages)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/brain_guide.ex lib/magus/brain/page.ex test/magus/agents/tools/brain/brain_guide_test.exs`

### Task B9: `brain_guide` set_page_type (classify)

**Files:** Modify `brain_guide.ex`; extend test.

**Interfaces:** `dispatch("set_page_type", %{page_id|page_title, type}, …)` sets the page's `type:` frontmatter via the same frontmatter-merge + `update_body` helper as B7. Returns `%{action: "set_page_type", page_id: …, type: type}`.

- [ ] **Step 1: Failing test:** `set_page_type` makes the page's frontmatter carry `type:`, surfaced by `get_guide` (as `type_template` when a matching template exists).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** (reuse the B7 frontmatter-merge helper).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): brain_guide set_page_type (classify a page)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/brain_guide.ex test/magus/agents/tools/brain/brain_guide_test.exs`

### Task B10: Curation categories (soft lint)

**Files:**
- Modify: `lib/magus/agents/tools/brain/read_brain.ex` (`curation_candidates/5` at 723; extend the returned map + `summarize_output`)
- Test: `test/magus/agents/tools/brain/read_brain_curation_test.exs`

**Interfaces:** `list_curation_candidates` output gains `untyped`, `off_template`, `unfiled` lists (metadata only, body-free), alongside the existing `drifted`/`stale`/`orphans`/`recently_changed`.

- [ ] **Step 1: Failing test** seeding: a `:page` with no `type` (untyped); a typed page missing a section its template declares (off_template); an orphan with no parent and no inbound wikilinks (unfiled). Assert each appears in its category. Scope assertions to the seeded brain id.
- [ ] **Step 2: Run, expect fail.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/brain/read_brain_curation_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.** `untyped`: content pages with blank `frontmatter["type"]`. `off_template`: for a typed page, cheap heading-set diff against its template page's headings. `unfiled`: no parent and no inbound wikilink (reuse the orphan query). Keep it body-free and heuristic (no LLM calls).
- [ ] **Step 4: Run, expect pass.** Same command. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(brain): lint pages against the Guide into curation candidates" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain/read_brain.ex test/magus/agents/tools/brain/read_brain_curation_test.exs`

### Task B11: Extract tool dispatch handlers into submodules

**Files:**
- Create: `lib/magus/agents/tools/brain/edit_brain/` submodules (group `dispatch/4` clauses by concern: pages, structure)
- Create: `lib/magus/agents/tools/brain/read_brain/` submodules (reads, search, curation)
- Modify: `edit_brain.ex` / `read_brain.ex` to delegate

**Interfaces:** No behavior change; the tools stay thin dispatchers delegating to concern modules.

- [ ] **Step 1: Extract** the largest cohesive handler groups into submodules, delegating from the tool's `dispatch/4`. Keep public tool schemas identical.
- [ ] **Step 2: Verify green.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/brain` and `MIX_ENV=test mix compile --warnings-as-errors`. Expected: unchanged pass.
- [ ] **Step 3: Commit.** `git commit -m "refactor(brain): split edit_brain/read_brain dispatch into concern modules" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- lib/magus/agents/tools/brain`

### Task B12: Rewrite the `brain_management` skill

**Files:** Modify `priv/skills/brain_management.md`.

- [ ] **Step 1: Rewrite** the skill to teach: the ICM framing; the default instructions (spec 3.3, verbatim); elicitation questions to ask when creating/growing a brain; how to author/evolve the Guide with `brain_guide` (`set_brain_guide`, `set_page_guide`, `define_type`, `set_page_type`), proposing a new type when a shape recurs (~3+ similar pages); reading the Guide first (`get_guide`); and that any page can carry tasks (a page with tasks is the former "plan"). Keep it concise. Add `brain_guide` to the frontmatter `tools:` list.
- [ ] **Step 2: Verify the skill loads.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/skills` (or the registry test). Expected: pass; skill parses.
- [ ] **Step 3: Commit.** `git commit -m "docs(skill): teach brains as ICM (defaults, elicitation, brain_guide)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- priv/skills/brain_management.md`

### Task B13: SPA Guide surfaces

**Files:**
- Create: `frontend/src/lib/components/brain/constitution-panel.svelte` (collapsible, editable markdown bound to `brain.instructions` via the brain update RPC)
- Create: `frontend/src/lib/components/brain/types-view.svelte` (list `:template` pages via `templatesForBrain` RPC)
- Modify: brain page/header to mount both (power-user, collapsible); show the active page's `type` and a "guide in effect" popover backed by a `getGuide` RPC or the tool.
- Regenerate: ash RPC/types.
- Test: `frontend/tests/constitution-panel.spec.ts`

- [ ] **Step 1: Regenerate RPC** so `instructions` / `templatesForBrain` are available client-side.
- [ ] **Step 2: Failing component test** for the constitution panel: renders current `instructions`, edits persist via the RPC (mock), collapses by default.
- [ ] **Step 3: Run, expect fail.** Run: `cd frontend && npm test -- constitution-panel`. Expected: FAIL.
- [ ] **Step 4: Implement** the panel + types view + `type` badge; wire into the brain page. SPA only.
- [ ] **Step 5: Run, expect pass**; then `npm run check && npm run build`.
- [ ] **Step 6: Commit.** `git commit -m "feat(brain/spa): constitution panel, types view, guide-in-effect" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- frontend/src/lib/components/brain frontend/src/lib/ash frontend/tests/constitution-panel.spec.ts`

### Task B14: Integration gate (e2e-live)

**Files:** Create `test/e2e_live/brain_guides_test.exs`.

- [ ] **Step 1: Write an e2e-live test** (`@tag :e2e_live`) that seeds a small messy brain (a few untyped, similar pages), gives the agent a task to add a related note, and asserts structurally: the agent classifies pages to a `type`, follows the template shape, files the new page under a sensible parent, and can add a task to an ordinary `:page`. Assert on data (frontmatter `type`, parent_page_id, task count), not on prose. Follow `test/e2e_live/support/live_e2e_case.ex` + `assertions.ex`.
- [ ] **Step 2: Run.** Run: `bin/test-e2e-live test/e2e_live/brain_guides_test.exs`. Expected: PASS.
- [ ] **Step 3: Full suite gate.** Run: `set -a && source .env && set +a && MIX_ENV=test mix test` and `cd frontend && npm run check && npm test`. Expected: green (scope any new count assertions to seeded rows).
- [ ] **Step 4: Commit.** `git commit -m "test(brain): e2e-live agent organizes a brain per its Guide" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" -- test/e2e_live/brain_guides_test.exs`

---

## Self-Review

**Spec coverage:**
- Constitution (spec 4.1) -> B1. Frontmatter keys (4.2) -> B2. Kind collapse (4.3) -> A4/A5. `:template` meta (4.3, 11) -> B3. Universal tasks + board (5) -> A7/A8. Injection (6) -> B4. Tools + org (7) -> B5-B9, B11. Skill (9) -> B12. Curation lint (8) -> B10. UI (10) -> A8, B13. Super Brain (11) -> B3. Migration/backfill (12) -> A5, B1 (lazy backfill needs no task). Testing (13) -> per-task + B14.
- Gap check: plan/spec removal fully covered A1-A6. Bottom-bar collapse state -> A8. Types index -> B4. All spec sections map to a task.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Deletion tasks name exact file:line; new-code tasks carry real code or a precise "mirror the pattern at <anchor>" instruction (justified: the subagents are capable and the surrounding patterns are the source of truth).

**Type/name consistency:** Tool = `brain_guide`; actions `get_guide` / `set_brain_guide` / `set_page_guide` / `define_type` / `set_page_type` used identically in B5-B9. Frontmatter keys `instructions` / `type`. Curation categories `untyped` / `off_template` / `unfiled`. Kind `:page` / `:template`. Component `TaskBoard` / `TaskBottomBar`. Domain fns `set_brain_instructions` / `templates_for_brain`. Consistent across tasks.
