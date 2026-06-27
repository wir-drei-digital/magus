# Magus as the project-state substrate: brain specs -> plans -> phases -> tasks, with delivery state

**Status:** draft 2026-06-25

**Builds on (being PORTED, not restated):**
- `2026-06-04-brain-plans-and-tasks-design.md` (the foundation: Plan = a Brain Page with `kind: :plan`; `Magus.Plan.Task` generalized to a conversation OR a brain page; `TaskDependency` DAG + `ValidateAcyclic`; `ready` calc + `:ready_for_plan`; atomic `:claim`/`:release`; `TaskEvent`; the plan board + brain overview).
- `2026-06-24-autonomous-task-coordination-design.md` (leased claims: `lease_expires_at`, `:heartbeat`, the AshOban reaper, `:ready_for_brain`, the per-plan task cap, `created_by_label`, `POST /api/v2/tasks/:id/heartbeat`).

Those two designs are implemented on a branch (`worktree-brain-plans-ui` @ `f0d93b04`) in the `magus-cloud` repo. They were built before the public/cloud split and never landed in open-source `magus`. This spec covers (a) **porting** that whole feature into open-source `magus`, and (b) the **new** layer that turns it into a project-state substrate: a phase level, a delivery lifecycle, and a spec page-kind. The coordination internals (deps/ready/claim/lease/reaper/subtasks/TaskEvent) are ported as-is and not restated here.

## Problem (the success criterion)

The state of in-flight work must be legible to **both the user and agents**, so nothing is forgotten or assumed-shipped. The concrete failure to design against actually happened during this work: a complete feature (Plans 1-4) lived on a branch in `magus-cloud`, was believed to be in main, and the repo split shipped without it. Plain task-status would NOT have caught this: every task was `done`. What was invisible was the **integration state**: "done, but never landed at its destination."

So the system's job is not "organize tasks." It is: at a glance, anyone can see the true state of all work, **including done-but-not-delivered**. Domain-agnostic: code gets *merged*, research gets *published*, a document gets *accepted/handed off*. The universal primitive is the gap between "the work is done" and "the outcome reached its destination."

## Decision (summary)

1. **Hierarchy = pages.** Spec (`kind: :spec`) -> Plan/Epic (`kind: :plan`) -> Phases (nested `:plan` pages) -> Tasks (records) -> subtasks. A "phase" is the *role* of a `:plan` page nested under another `:plan` page; no new page-kind for phases.
2. **Delivery lifecycle** on every `:plan` page: `draft -> active -> done -> delivered`. `done` is auto-derived from the task rollup (recursive over phases); `delivered` is an always-explicit human/agent gate. The overview's headline signal is **done-but-not-delivered** (the stranded-work alarm).
3. **Spec is a lightweight typed kind** (`:spec`) linked to its plan(s). Specs get NO separate delivery lifecycle: a spec's "delivery" is its plan reaching `delivered`.
4. **Magus serves the truth; the orchestrator enforces.** The done-but-not-delivered state is queryable by agents/CLI; active guardrails (e.g. "block a release if plans are undelivered") live in the orchestrator, not here.

## Design

### 1. Page hierarchy and kinds

`Brain.Page` already has a real `attribute :kind, :atom` (`one_of: [:page, :plan]`) with a promote/demote action and a cached `frontmatter` map. Extend it:

- **`kind` gains `:spec`** -> `one_of: [:page, :plan, :spec]`. The promote/demote action accepts the new value. The frontend already branches on `pageData.kind`.
- **Phases reuse `:plan` + page nesting.** Brain pages nest via `parent_id`. A `:plan` page whose parent is also a `:plan` page IS a phase. Tasks attach to any `:plan` page (a top-level plan OR a phase). No `:phase` kind, no new entity. This keeps "epic = plan-page, arbitrary nesting" from the 2026-06-04 design.
- **Spec -> plan link.** A `:plan` page carries a nullable `spec_page_id` self-reference to the `:spec` page it implements (explicit + queryable, so the tree/overview can resolve the chain without parsing the body). Navigation is bidirectional: a spec lists the plans referencing it (a reverse read), a plan shows its spec. In-body `[[wikilinks]]` to the spec remain a convenience but are not the source of truth for the typed edge.

### 2. Delivery lifecycle (the anti-stranding mechanism)

The lifecycle is **mostly computed**, with minimal stored state, so it cannot drift (the original "stale todo list needs manual cleanup" pain).

**Stored on `:plan` pages (new `Page` attributes):**
- `delivered_at :: utc_datetime_usec | nil` (nil until an explicit `mark_delivered`; the only manual gate).
- `delivery_ref :: string | nil` (optional free text: a PR URL, a published link, a hand-off note; domain-agnostic).

**Computed `lifecycle :: :draft | :active | :done | :delivered`** (a calc, recursive over child phases):
- `:delivered` if `delivered_at` is set.
- else `:done` if the page has at least one non-cancelled task or child phase AND every non-cancelled direct task is `done` AND every child `:plan` page (phase) is itself `:done` or `:delivered`. (A plan with zero tasks and zero phases is never `:done`.)
- else `:active` if any direct task is `in_progress`/`done` or any child phase is past `:draft`.
- else `:draft`.

**The detectors (what the overview surfaces):**
- **Done-but-not-delivered:** `lifecycle == :done` (all work complete, `delivered_at` nil). This is the exact lost state, generalized. Read: `:stranded_plans` for a brain (all `:plan` pages whose computed lifecycle is `:done`).
- **Stale-in-done:** a plan in `:done` for longer than a threshold is escalated visually (the "you forgot to land this" nudge). Threshold is config, not a new model.

`mark_delivered` (and an `undeliver` for mistakes) are explicit actions that set/clear `delivered_at` + `delivery_ref`. Marking a parent plan delivered does NOT auto-deliver its phases (and vice versa): each level is delivered explicitly, so a half-shipped plan shows precisely which phases landed.

### 3. Coordination (ported as-is from `magus-cloud` @ f0d93b04)

No design change; ported and re-verified in open-source `magus`:
- `Magus.Plan.Task` (conversation OR `brain_page` container), priority, single-level subtasks.
- `TaskDependency` DAG + `ValidateAcyclic`; the `ready` calc (open + unassigned + all dependencies done) + `:ready_for_plan` / `:ready_for_brain`. This is the "what is safe to start" signal agents pull on.
- Atomic `:claim` (advisory lock), `:release`, leased claims (`lease_expires_at` + `:heartbeat` + renew-on-activity), the AshOban `:reap_expired_claims` reaper (`*/2` cron) returning expired-lease tasks to the pool.
- **Plan-task scoping (the leak fix) is preserved:** `RenewLease` and `is_stale` only act on tasks with a `brain_page_id`. Conversation tasks are never leased or reaped.
- Per-plan open-task cap (`PlanTaskCapReached`), `created_by_label` lineage, `TaskEvent` trail.
- Because tasks attach to any `:plan` page, the same board/claim/ready machinery works at the **phase** level for free (a phase is a `:plan` page).

### 4. Views: project state at a glance

- **Unified plan tree** (new; the model-A view): for a plan, render Spec -> Plan -> Phases -> Tasks in one screen, each node showing its computed lifecycle, the `ready`/blocked task counts, and the done-but-not-delivered flag. This is the "what is the state of this project" surface the user operates on.
- **Brain overview** (ported + extended): rolls up every `:plan` page in a brain; adds a **stranded-work section** (done-but-not-delivered, stale-in-done first) so an at-a-glance scan answers "is anything finished-but-not-landed?"
- **Per-page board** (ported): the kanban/list board for a single plan or phase's tasks.
- **Agent/CLI parity:** everything the user sees is queryable. Agents pull `ready` work; the orchestrator can query `:stranded_plans` before risky actions (split/release) and decide. Magus serves the state; it does not enforce the gate.

### 5. API / CLI surface

Ported `/api/v2` (tasks list/create/show/update, claim, release, heartbeat, dependencies) plus:
- Plan/phase lifecycle: read the computed `lifecycle`; `mark_delivered` (set `delivery_ref`); `undeliver`.
- `stranded_plans` query for a brain (done-but-not-delivered).
- Spec <-> plan link read/set.
- Token-authenticated as today (`/api/v2` token = the user); the `magus` CLI (separate repo) consumes these.

## Integration approach (the port)

This is implementation guidance for the plan, not a design choice:
- Source of truth for the ported code is the `magus-cloud` branch checkout at `/Users/daniel/Development/magus-cloud/.claude/worktrees/brain-plans-src` (@ `f0d93b04`). The feature footprint: `lib/magus/plan/**` (resources, `checks/`, `errors/`, `task/changes/`, `task_dependency/`), `lib/magus_web/api/v2/tasks_controller.ex` (+ v2 helpers + `/api/v2` routes in the router), `lib/magus_web/channels/task_channel.ex`, the `config` lease/queue settings, `frontend/src/lib/components/plan/**`, `frontend/src/routes/brain/{overview,page}/**`, `frontend/src/lib/realtime/task-updates.ts`, and the matching test files.
- Open-source `magus` already has the ORIGINAL `Magus.Plan.Task` (conversation-only; no `brain_page_id`, deps, board, API, or lease). The port REPLACES/EXTENDS those modules and ADDS the rest.
- **Migrations and `ash_typescript` codegen are regenerated in open-source `magus`** against its own history. The cloud branch's migration timestamps/snapshots and generated TS do not transfer 1:1; the plan runs `mix ash.codegen` + `mix ash_typescript.codegen` here and commits the results.
- Divergence from the split is resolved per file (e.g. `config/config.exs` ash_domains differs: cloud carries `Magus.Billing`; open-source does not). The plan flags each touched file that differs between repos.
- The new layer (spec kind, phase nesting support, the delivery lifecycle + detectors, the unified tree view, the stranded query) is built ON TOP of the ported feature, in the same branch, so the PR carries the whole thing.

## Out of scope (north-star, later)

- Orchestrator-enforced guardrails (magus only serves the `stranded_plans` query; Legend/CLI decides whether to block a split/release).
- Auto-detecting git merge state. `delivered` is human/agent-confirmed, never inferred from git.
- Per-plan custom delivery labels (the generic `delivered` + `delivery_ref` suffices; revisit if the word grates).
- Full Legend wiring (separate repo).
- Deeper task nesting beyond single-level subtasks (phases cover the grouping need).

## Affected modules (orientation, not exhaustive)

- `lib/magus/brain/page.ex` -> `kind` gains `:spec`; new `delivered_at` + `delivery_ref` attributes; `lifecycle` calc (recursive); `:stranded_plans` read; `mark_delivered`/`undeliver` actions; spec<->plan link attribute/relationship.
- `lib/magus/plan/**` -> ported in full (Task, TaskDependency, TaskEvent, checks, errors, changes incl. the plan-task-scoped RenewLease/is_stale, the reaper trigger).
- `lib/magus_web/api/v2/tasks_controller.ex` + router + `task_channel.ex` -> ported; controller gains lifecycle + stranded endpoints.
- `frontend/src/lib/components/plan/**` + `frontend/src/routes/brain/**` -> ported board/overview; new unified tree view + lifecycle badges + stranded-work section.
- `config/config.exs` (+ runtime) -> lease TTL, reaper queue, task cap, stale-in-done threshold (resolve the ash_domains divergence vs cloud).
- `priv/repo/migrations/**` + `priv/resource_snapshots/**` -> regenerated here.
- `frontend/src/lib/ash/{ash_rpc,ash_types}.ts` -> regenerated here.

**Sequencing:** port the foundation first (so the feature exists + tests green in open-source magus), then layer the new project-state design on top, then the unified view, then full verification + PR.
