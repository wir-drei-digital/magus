# Brain Guides: brains as Interpretable Context (ICM)

Status: Approved (planning)
Date: 2026-07-07
Author: Daniel + Claude
Scope: Phase 1 (foundation) plus a page-model consolidation. Proactive brain creation is Phase 2, tracked separately.

## 1. Summary

Two things, one coherent change:

1. **Brain Guides.** Give every brain a small, agent-maintained "operating manual" (a
   **Guide**) that loads just-in-time and keeps the brain consistently and interpretably
   organized. Agents write and evolve the Guide; users steer by talking and can inspect or
   edit it in the UI. Guidance that agents ignore surfaces as soft curation nudges, never as
   hard errors.
2. **Page-model consolidation.** Stop letting `kind` encode semantics. Collapse `kind` to
   `:page` + `:template`, make tasks a universal capability on any page (a collapsible
   bottom-bar board on every brain page), and drop the hardcoded plan/spec coupling in favor
   of the generic ICM (agent-defined `type` plus wikilinks/typed relationships).

Both express the same principle: a brain becomes an **Interpretable Context Methodology
(ICM)** space where the organization is legible and its structure comes from agent-authored
guidance and agent-defined types, not from hardcoded enums.

## 2. Background and problem

Agents capture into brains via `edit_brain` / `read_brain` with essentially no conventions,
so pages drift into inconsistent shapes and the brain becomes hard to navigate. This is the
failure mode of every accumulate-only agent memory system (Generative Agents, HippoRAG):
without a governing structure, volume degrades usefulness.

Clean knowledge systems converge on one fix: separate a freely growing content layer from a
governed structural layer, and admit new content by fitting it to the structure (the shared
principle behind controlled vocabularies, Obsidian fileClass, Notion typed databases,
Wikidata constraints). For an agent-run brain, that structure is best expressed as
**instructions that load when relevant**, exactly how coding agents use layered instruction
files (CLAUDE.md, AGENTS.md, Cursor/Windsurf/Copilot rules) and how the "Interpretable
Context Methodology" paper (arXiv:2603.16021) frames folders-plus-markdown as an agent
architecture.

Separately, the page `kind` enum currently overloads two ideas: a structural/system role and
agent-facing semantics/behavior (`:plan` renders a task board and carries a delivery
lifecycle; `:spec` is a requirements doc a plan links to). That coupling is too specific and
is better solved by the generic ICM.

### Non-goals

- **Not a strict memory system.** No entity resolution, deduplication, bitemporal
  invalidation, or write-blocking validation. Strict memory is the Memory domain and the
  Super Brain, which stay separate. Brains are an ICM, not a fact store.
- **Not proactive creation (yet).** Agents autonomously creating brains from observed user
  interest is Phase 2, layered on this foundation and the existing heartbeat / AgentRun
  autonomy rails. It gets its own spec.
- **No backwards compatibility for plans/specs.** There is no relevant production plan/spec
  data, so `:plan`/`:spec` removal is a clean deletion with no data migration.
- **SPA only.** UI work targets `frontend/`. The classic LiveView brain UI keeps working off
  the shared backend fields; we do not add new panels there.

## 3. Design overview

### 3.1 `kind` vs `type`: the clean split

- **`kind`** is a minimal, system-owned structural role: `:page` (content) and `:template`
  (a Guide template). The system uses `kind` to decide extraction, listing, and whether a
  page shows a task board. Nothing else.
- **`type`** is agent-defined semantics living in frontmatter: `Paper`, `Person`, `Spec`, and
  so on. Brains grow their own vocabulary.
- **Capabilities are universal, not kinds.** "Has tasks" is available on any content page.

Under this split, `:plan` and `:spec` dissolve: "spec" is just a `type`, and "plan" is any
page that happens to carry tasks. "This plan implements that spec" becomes a `[[wikilink]]`
or a typed relationship, not a hardcoded FK.

### 3.2 The Guide cascade

A brain's effective Guide is a four-layer cascade. Later layers extend or override earlier
ones, and each loads only when relevant.

| Layer | Home | Scope | Load trigger | Authored by |
|---|---|---|---|---|
| **ICM defaults** | the `brain_management` skill | every brain (baseline) | agent loads the skill on demand | us, once |
| **Brain constitution** | `instructions` field on the brain | one brain | brain is open (always-on) | agent, user-steerable |
| **Section guide** | `instructions:` frontmatter on a page | that page and its descendants | agent works in that subtree | agent, user-steerable |
| **Type template** | a template page (`kind: :template`) | pages of one brain-defined type | agent creates/edits a page of that type | agent, user-steerable |

"Brains are ICMs by default" means a new or un-guided brain already behaves consistently
because the baseline conventions live in the skill; the constitution only customizes. Users
write nothing: the agent elicits direction conversationally and writes the Guide itself.

### 3.3 The default instructions (baseline ICM conventions)

Encoded in the `brain_management` skill, applied to every brain:

- One concept per page (atomic notes). Split a page when it grows two distinct subjects.
- Search before create: prefer extending an existing page over creating a near-duplicate.
- Every content page declares a `type` (or the agent classifies it).
- Link related pages with `[[wikilinks]]`; keep an index / Map-of-Content page per area.
- No orphans: file a new page under a sensible parent and link it from somewhere.
- When unsure how to organize, ask the user a short, specific question.

Drawn from the research: atomic and densely-linked notes (Zettelkasten / evergreen notes,
and A-MEM which implements them for agents), Maps-of-Content index pages, search-before-create
as the lightweight anti-duplication gate, and no-orphans from taxonomy governance.

## 4. Data model changes

### 4.1 Brain constitution: `instructions` on the brain

`lib/magus/brain/brain_resource.ex`

- Add attribute (near line 90): `attribute :instructions, :string, public?: true`.
- Accept it in `create` (line 28) and `update` (line 36); add a focused
  `update :set_instructions` accepting only `[:instructions]` for the tool + policies.
- `mix ash.codegen` generates the migration (one nullable text column).

A field (not a page) because the constitution must be reliably always-on and surfaced as a
single editable panel. Section guides and type templates are page-scoped and live on pages.

### 4.2 Section guide and page type: frontmatter keys

`lib/magus/brain/frontmatter.ex`

- Extend `@known_keys` (line 30):
  `~w(icon tags aliases created modified instructions type)`.
- Normalize in `normalize_known_keys/1` (lines 125-130): `instructions` and `type` coerced to
  trimmed strings. They are already preserved opaquely today, so this is hardening.
- The parsed map is already cached on `page.frontmatter` by the `update_body` pipeline, so
  `type` and `instructions` are queryable without a new column.

`instructions:` is the **section guide**: it applies to the page and everything nested
beneath it (subtree inheritance, walked at injection time). `type:` binds a content page to
its brain-defined type (resolved by name, case-insensitive, within the brain).

### 4.3 `kind` collapse: remove `:plan` / `:spec`, add `:template`

`lib/magus/brain/page.ex`, line 583:
`constraints one_of: [:page, :template]` (was `[:page, :plan, :spec]`).

`:template` pages hold a type's template (title = type name, body = skeleton + guidance).
They are excluded from normal listings and from graph extraction, and never show a task board.

Because there is no relevant prod data, everything below is deleted outright (no migration of
existing rows). Remove:

| File | Lines | Item |
|---|---|---|
| `lib/magus/brain/page.ex` | 620-628 | attribute `:delivered_at` |
| `lib/magus/brain/page.ex` | 630-633 | attribute `:delivery_ref` |
| `lib/magus/brain/page.ex` | 643-649 | relationship `:spec_page` |
| `lib/magus/brain/page.ex` | 657-658 | relationship `:implementing_plans` |
| `lib/magus/brain/page.ex` | 211-216 | action `:set_kind` |
| `lib/magus/brain/page.ex` | 218-223 | action `:set_spec` |
| `lib/magus/brain/page.ex` | 225-236 | action `:mark_delivered` |
| `lib/magus/brain/page.ex` | 238-245 | action `:undeliver` |
| `lib/magus/brain/page.ex` | 336-346 | read `:plans_for_spec` |
| `lib/magus/brain/page.ex` | 348-368 | read `:stranded_plans` |
| `lib/magus/brain/page.ex` | 691-693 | calculation `:lifecycle` |
| `lib/magus/brain/page/calculations/lifecycle.ex` | whole module | plan lifecycle calc |
| `lib/magus/brain/page/preparations/filter_done_plans.ex` | whole module | stranded-plans filter |
| `lib/magus/brain/brain.ex` | 103-107 | 4 domain fns (set_page_spec, plans_for_spec, mark_page_delivered, stranded_plans) |
| `lib/magus_web/api/v2/plans_controller.ex` | whole controller | 6 dead endpoints |
| `lib/magus_web/core_router.ex` | 509-518 | 6 plan routes |

Generalize (not remove):

- `has_many :child_plan_pages` (page.ex 667-670): either drop, or generalize to "child pages"
  if the tree UI needs a typed children query. Default: drop; the generic children relation
  already exists.
- `has_many :tasks` (page.ex 660-663): survives; drop the ":plan page" wording. Tasks are now
  universal.

Note: `lib/magus/agents/sub_agent/resumer.ex:130` calls `mark_delivered` on an **AgentRun**,
not a Page. Leave it alone. Confirm no other `kind == :plan` / `:spec` references remain via a
final grep before closing the task.

`mix ash.codegen` + `mix ash.migrate` for the schema (drop columns, shrink `kind` constraint).
Never `mix ash.reset`.

## 5. Universal tasks and the collapsible board

The task backend is already page-agnostic. Task belongs to exactly one of a conversation or a
`brain_page` (`lib/magus/plan/task.ex`), keyed by `brain_page_id`; reads (`for_plan`,
`ready_for_plan`, `for_brain`), policies (`ActorCanAccessTaskPage`), the task channel
(`tasks:plan:<page_id>`, `tasks:brain:<brain_id>`), and PubSub are all keyed by page id, not
by kind. So this is consolidation, not new plumbing.

Changes:

- **Un-gate the board.** `frontend/src/routes/brain/page/[pageId]/+page.svelte:522-526`
  currently renders `PlanBoard` only when `pageData.kind === 'plan'`. Render it for content
  pages (`kind === 'page'`, not `:template`) as a **collapsible bottom bar** present on every
  brain page.
- **Rename** `plan-board` to `task-board` (component + store) and drop plan/spec language.
- **Remove dead frontend plan/spec logic**: `plan-tree-store.svelte.ts` spec/plan filtering
  and `isStranded` (lines ~51-120), `brain-nav.svelte:42` kind enum, and the `specPageId` /
  `deliveredAt` / `deliveryRef` TS fields (auto-regenerate from AshTypescript after the schema
  shrinks).
- **Bottom-bar collapse state** is a small new piece of client state (localStorage per brain,
  or a lightweight pane-state row). `TaskPaneState` is conversation-scoped and unrelated;
  do not overload it.
- **Task-status naming.** Task keeps its own `status` (`todo`/`doing`/`done`/`cancelled`/
  `archived` per `active_tasks`). Page-level "done-ness" is derivable from tasks if ever
  needed, so the removed `:lifecycle` calc is not replaced.

Agent task tools (`CreateTask` / `UpdateTask` / `ListTasks` / `ClearTasks`, Plan domain)
already operate on any page's tasks; only their docs need the "plan page" wording dropped.

## 6. Context injection

`lib/magus/agents/context/brain_context.ex`, `compose/6` (lines 110-157). Add a
`### Brain Guide` section to the assembled `sections` list (lines 136-154):

1. **Constitution** (always): `brain.instructions`, capped at a soft budget (target under
   ~200 lines, matching CLAUDE.md guidance; truncate with a note if over).
2. **Inherited section guides** (current location): walk the active page's ancestor chain
   (reuse `Hierarchy.ancestor_pages/2`, already used at line 252), collect each ancestor's
   `instructions` frontmatter plus the active page's own, ordered root to current (closest
   last, nearest wins, matching CLAUDE.md precedence).
3. **Types index** (always, compact): one line per type (name + purpose) from the brain's
   `:template` pages, so the agent always knows which types exist. The full template loads on
   demand (Section 7), not inline. Deliberate progressive disclosure.

Also surface the active page's `type` in the existing frontmatter line (line 131 / 186-196).
Token budget stays bounded: constitution + current-location guides + compact types index are
cheap; other subtrees' guides and full templates load lazily.

## 7. Agent tools and tool organization

### 7.1 Surface: split by concern, not by action

Tools are registered into the system prompt up front (ReactStrategy), so each tool's schema
costs baseline tokens every turn. That rules out many micro-tools; it also rules out one
mega-tool whose conditional param union is ambiguous. The middle path (a few cohesive tools)
follows Anthropic's tool-design guidance (minimal, unambiguous, well-differentiated).

Decision (confirm in review):

- Keep **`read_brain`** / **`edit_brain`** for content CRUD + search (the hot path).
- Add a new **`brain_guide`** tool for the ICM structural concern:
  - `set_brain_guide` (brain_id, instructions): write the constitution via
    `BrainResource.set_instructions`.
  - `set_page_guide` (page_id|title, instructions): set a page's `instructions:` frontmatter
    (section guide) through `update_body`.
  - `define_type` (brain_id, type_name, template_body, description): create/update the
    `:template` page for a type.
  - `set_page_type` (page_id|title, type): set `type:` frontmatter through `update_body`.
  - `get_guide` (brain_id, page_id?): return the effective Guide for a location (constitution
    + inherited section guides + the type template in effect). Basis for the UI transparency
    view.
- Task tools already exist (Plan domain) and are page-agnostic; keep them as the `brain_tasks`
  concern, docs updated.

All page-scoped Guide writes go through `update_body`, preserving versioning (paper-trail),
optimistic locking, and derived-state rebuild.

### 7.2 Code organization

Independent of the surface: extract the `dispatch/4` handlers in `edit_brain.ex` (~1,600
lines) and `read_brain.ex` into per-concern submodules so the tool modules stay thin
dispatchers. Do it while we are already editing these files.

### 7.3 `read_brain` curation

Extend `curation_candidates/5` (read_brain.ex:723) with the new categories in Section 8.

## 8. Soft linting to curation

Guidance never checked rots. Close the loop cheaply, without blocking writes.

- Extend `curation_candidates/5` with body-free categories:
  - `untyped`: a content page (`kind: :page`) with no `type`.
  - `off_template`: a typed page missing sections its type template declares (cheap heading
    diff against the template page; no LLM call).
  - `unfiled`: a page with no parent and no inbound wikilinks (reuse the orphan signal).
- These surface through the existing `list_curation_candidates` output the heartbeat curation
  pass already consumes, so the agent self-corrects on its next pass; the UI may also show
  them. Deeper semantic checks (for example "this duplicates an existing page") are LLM-based
  and run only in the batched heartbeat pass, never per write.
- No change to the `update_body` hot path: linting is read-time / scheduled, not a write gate.

## 9. The `brain_management` skill (the meta-guide)

Rewrite `priv/skills/brain_management.md` to teach the ICM methodology (the "how to run any
brain as an ICM" layer; each brain's constitution is the instance-guide). Add:

- **Framing**: a brain is an interpretable, self-organizing knowledge system; the organization
  is the value.
- **Default instructions** (Section 3.3), verbatim, so every brain inherits them.
- **Elicitation questions**: what to ask when creating or growing a brain (purpose, page
  shapes worth standardizing, filing preferences), phrased as short optional questions. Users
  are lazy about writing rules but give direction when asked.
- **Authoring/evolving the Guide** with the `brain_guide` tool: write the constitution,
  section guides, and type templates; propose a new type when a shape recurs (roughly 3+
  similar pages).
- **Read the Guide first** (`get_guide` or injected context) before writing.
- **Tasks anywhere**: any page can carry tasks; use the task tools; a page with tasks is what
  used to be a "plan."

Keep it concise (loaded on demand). Per-brain specifics belong in that brain's constitution.

## 10. Interpretability and UI (SPA)

The interpretability claim (the arXiv:2603.16021 framing) is the differentiator: a brain can
show why it is shaped the way it is.

- **Constitution panel**: brain-level, collapsible, editable markdown (power-user affordance,
  not front-and-center). Reads/writes `brain.instructions`.
- **Types view**: list the brain's `:template` pages with their templates; editable.
- **Per-page "guide in effect"**: show the page's `type` and, on demand, the effective Guide
  (from `get_guide`). Makes "why is this page shaped this way" answerable.
- **Task board**: the collapsible bottom bar (Section 5), on every content page.
- **Curation surfacing**: show `untyped` / `off_template` / `unfiled` as gentle, dismissable
  suggestions.

SPA only (`frontend/`). Backend fields are shared, so the classic UI keeps working without
these panels.

## 11. Super Brain handling

Instructions and templates are meta, not knowledge, and must not pollute the graph.

- `EnqueueSuperBrainExtraction` (page.ex:197): skip `kind: :template` pages.
- Ensure frontmatter (including `instructions:` and `type:`) is stripped before extraction of
  content pages, matching how the chunker already strips it for `PageChunk`. Verify and strip
  if not already done.

## 12. Migration and backfill

- **Plans/specs**: clean removal, no data migration (no relevant prod data). Schema migration
  drops `delivered_at` / `delivery_ref` / `spec_page` and shrinks the `kind` constraint.
- **Guides**: lazy backfill. Existing brains have no constitution and no typed pages; nothing
  is rewritten eagerly. As agents next work in a brain they propose a constitution and types
  and classify pages incrementally, following the skill.
- **Frontmatter keys**: additive (jsonb cache), no data-shape migration.
- Migrations via `mix ash.codegen` + `mix ash.migrate`. Never `mix ash.reset`.

## 13. Testing

- Remove dead tests: `plan_lifecycle_test`, `page_kind_test`, `page_lifecycle_test`,
  `page_spec_link_test`, the plan/spec parts of `resumer_test`, and `plan-board.spec.ts`
  (rework as `task-board`).
- Unit: `Frontmatter` normalization of `type` / `instructions`; `BrainContext` Guide assembly
  (constitution + inherited-guide ordering + types index; token caps).
- Unit: `curation_candidates` detects `untyped` / `off_template` / `unfiled` on seeded pages
  (scope assertions to seeded rows; the shared test DB has leaked rows).
- Integration: `brain_guide` actions round-trip (set constitution, define type, classify page,
  set section guide) through `update_body` (versioning + lock preserved); tasks create and
  render on an ordinary `:page` (not just former plans).
- E2E-live: give an agent a small messy brain and a task; assert it classifies new pages to a
  type, follows the template shape, files under a sensible parent, and can add tasks to any
  page. Assert structurally (data-* / counts / frontmatter), not on copy.

## 14. Phasing

**Phase 1 (this spec):** the Guide cascade (defaults + constitution + section guides + type
templates), context injection, the `brain_guide` tool + file extraction, the rewritten skill,
soft linting/curation, the SPA Guide surfaces, Super Brain exclusion, lazy backfill, AND the
page-model consolidation (kind collapse, universal tasks + collapsible board, plan/spec
removal).

**Phase 2 (separate spec): proactive curation.** Detect sustained user interest (across
conversations / memory), propose or auto-create a brain, and seed it per these conventions, on
the heartbeat to AgentRun to RunOrchestrator rails with `WakeupPreamble`. Requires a permission
model (propose vs. auto-create-and-notify) and an interest-detection signal. Out of scope here.

## 15. Open questions and risks

- **Decided: page-level lifecycle/delivery is dropped.** The plan lifecycle calc, delivery
  gates, and stranded-plan detection are removed outright; task-level status is enough.
- **Decided: tool split.** `brain_guide` as a new tool plus internal module extraction (7.1/7.2).
- **Template storage** chosen as `:template` pages (ICM-native, versioned, chat-editable).
  Alternative was a structured `page_types` field on the brain; revisit only if template pages
  are awkward in the tree UI.
- **Type explosion**: agents could invent near-duplicate types. Mitigation: the skill says
  "reuse an existing type unless clearly distinct"; a later curation check can flag
  low-population types for merge. Not built in Phase 1.
- **Injection token budget** on very large / deeply nested brains: bounded by loading only the
  current ancestor chain + compact types index; full templates load on demand. Monitor.

## 16. Research basis (selected)

- Folders + markdown as agent architecture: arXiv:2603.16021 (Interpretable Context
  Methodology).
- Layered instruction files and load-when-relevant modes (always-on / glob / semantic /
  manual): CLAUDE.md memory docs, AGENTS.md, Cursor/Windsurf/Copilot rules; Anthropic
  "Effective context engineering for AI agents" (just-in-time, progressive disclosure) and
  "Agent Skills" (3-level disclosure).
- Accumulate-only degrades; a governing structure is required: Generative Agents
  (arXiv:2304.03442), contrasted with reconcile-on-write systems (Mem0 arXiv:2504.19413,
  LangMem, Zep/Graphiti arXiv:2501.13956). We take the light (guidance + soft lint) end.
- Human methodologies encoded as machine rules: Zettelkasten / evergreen notes (and A-MEM
  arXiv:2502.12110), Maps of Content, no-orphan taxonomy governance.
- Tool design (few cohesive tools over many micro-tools or one mega-tool): Anthropic "Building
  effective agents" (agent-computer interface) and "Code execution with MCP".
- Separate content layer from governed structure layer: Obsidian fileClass, Notion typed
  databases, Wikidata constraints, SKOS/SHACL.
