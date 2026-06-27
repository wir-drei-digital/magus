# Magus Project-State Substrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-land the brain plans/tasks/coordination feature (built in `magus-cloud`, stranded on a pre-split branch) into open-source `magus`, then extend it into a project-state substrate: a phase level, a delivery lifecycle, a `:spec` page kind, and a unified tree view, so the true state of all work (including done-but-not-delivered) is legible to user and agent.

**Architecture:** Two phases. **Phase A (port):** copy the feature-owned modules from the cloud branch checkout, merge the feature's additions into shared files, regenerate migrations + ash_typescript codegen against OSS magus's own history, green the tests. **Phase B (new layer):** add the delivery lifecycle + `:spec` kind + spec↔plan link + stranded detector + unified tree view, TDD. **Phase C:** full verification, then the controller opens a PR.

**Tech Stack:** Elixir/Phoenix, Ash 3.x + AshPostgres, AshOban, Oban, pgvector; SvelteKit 2 + Svelte 5 runes + Tailwind v4; ash_typescript RPC.

**Spec:** `docs/superpowers/specs/2026-06-25-magus-project-state-design.md`

## Global Constraints

- **Worktree:** all work in `/Users/daniel/Development/magus/.claude/worktrees/magus-project-state` on branch `worktree-magus-project-state` (open-source `magus`). NEVER `cd` out for git; NEVER `git add .`/`git add -A` (deps + frontend/node_modules are symlinks). Stage explicit paths only. Verify branch before every commit.
- **Port source (read-only):** the cloud feature branch is checked out at `/Users/daniel/Development/magus-cloud/.claude/worktrees/brain-plans-src` @ `f0d93b04`. Treat it as the source of truth for ported CODE (copy files from there). Do NOT copy its migrations, resource snapshots, or generated TS (regenerate those here). Do NOT modify the cloud checkout.
- **Test env prefix** (every backend mix command): `export MIX_TEST_PARTITION=_mps && set -a && . /Users/daniel/Development/magus/.env && set +a &&`. The isolated DB `magus_test_mps` is already set up.
- **Never** `mix ash.reset`. Use `mix ash.codegen` + `mix ash.migrate`.
- **No em dashes** (U+2014) in any code/comment/doc. Use `:` or `-`.
- **CI parity:** before each commit run `MIX_ENV=test mix compile --warnings-as-errors`; for frontend run `npm run check` (in `frontend/`).
- **Codegen + migrations are regenerated HERE.** After any resource change: `mix ash.codegen <name>` + `mix ash.migrate`; after any rpc/public-attribute change: `mix ash_typescript.codegen`. Commit the generated migration, snapshot, `ash_rpc.ts`, `ash_types.ts`.
- **Plan-task scoping is law** (the leak fix, already in the cloud source): `RenewLease` and `is_stale` act ONLY on tasks with a `brain_page_id`. Conversation tasks are never leased or reaped. Do not regress this.
- **Lease TTL** `900`s; **reaper cron** `*/2 * * * *`; **task cap** `200`; **reaper queue** `plan_task_cleanup`.
- **Oban testing** is `:manual`: AshOban triggers are tested with `AshOban.Test.schedule_and_run_triggers/1` (inline drain), NOT `AshOban.run_trigger/2`.
- **Delivery lifecycle (Phase B):** `delivered_at` + `delivery_ref` are the only stored fields; `lifecycle` (`:draft|:active|:done|:delivered`) is COMPUTED; `done` requires >=1 non-cancelled task/phase with all complete (recursive); `delivered` is an explicit gate. Phases are nested `:plan` pages (no `:phase` kind). Specs (`:spec`) have NO delivery lifecycle.

## File disposition map

**CLEAN COPY** (feature-owned; copy file/dir from cloud src, adapt only cloud-only refs):
- `lib/magus/plan/**` (24 files: resources Task/TaskDependency/TaskEvent/TaskPaneState, `checks/`, `errors/`, `task/changes/**`, `task_dependency/changes/**`). REPLACES OSS magus's smaller original Plan domain wholesale.
- `lib/magus_web/api/v2/tasks_controller.ex`, `lib/magus_web/api/v2/overview_controller.ex` (new).
- `lib/magus_web/channels/task_channel.ex` (new).
- `frontend/src/lib/components/plan/**` (new dir).
- `frontend/src/routes/brain/overview/**` (new dir).
- `frontend/src/lib/realtime/task-updates.ts` (new).
- Test files under `test/magus/plan/**`, `test/magus_web/api/v2/tasks_controller_test.exs`, `test/magus_web/api/v2/overview_controller_test.exs`, and the frontend `*.test.ts` / `frontend/tests/*.spec.ts` for plan/overview.

**MERGE** (shared file OSS already has; apply the feature's additions, diff cloud-vs-OSS):
- `lib/magus/brain/page.ex` -> add the `kind` attribute (`one_of: [:page, :plan]`), the promote/demote action, and any frontmatter `kind` sync. (OSS has NO `kind` yet.)
- `lib/magus/brain/checks/brain_access_filter.ex` -> add the `:via_brain_page` and `:via_task_brain_page` paths.
- `config/config.exs` -> add `task_lease_ttl_seconds: 900`, `max_open_tasks_per_plan: 200`, the `plan_task_cleanup: 1` Oban queue. PRESERVE OSS's `ash_domains` (it differs from cloud: no `Magus.Billing`).
- `lib/magus_web/core_router.ex` -> add the `/api/v2` task routes (+ overview route).
- `lib/magus_web/channels/user_socket.ex` -> register the task channel(s).
- `lib/magus_web/api/v2/api_view.ex`, `controller_helpers.ex` -> verify they expose what `tasks_controller` needs (`ApiView.data/1,2`, `error/2,3`; `to_atom_map/2`, `ash_errors/1`, `not_found/1`); add any missing helper.
- `frontend/src/lib/ash/api.ts` -> add the `PlanTask`/`TaskEventEntry`/`TaskDependencyEntry` types + RPC wrappers + `TaskEventKind`/`TaskStatus`/`TaskPriority`.
- `frontend/src/routes/brain/page/[pageId]/+page.svelte` -> mount the plan board when `pageData.kind === 'plan'`.

**REGENERATE HERE** (never copy from cloud): `priv/repo/migrations/**`, `priv/resource_snapshots/**`, `frontend/src/lib/ash/ash_rpc.ts`, `frontend/src/lib/ash/ash_types.ts`.

---

## Phase A: Port the foundation + coordination

### Task 1: [A1] Brain.Page `kind` + brain-access-filter paths (the plan-page foundation)

**Files:**
- Modify: `lib/magus/brain/page.ex` (add `kind` attribute + promote/demote action)
- Modify: `lib/magus/brain/checks/brain_access_filter.ex` (add `:via_brain_page`, `:via_task_brain_page`)
- Generated: a migration adding `plan_pages.kind` (or `pages.kind` - match the real table) + snapshot
- Test: `test/magus/brain/page_kind_test.exs`

**Interfaces:**
- Produces: `Brain.Page` has `kind :: :page | :plan` (default `:page`), a promote/demote action, and `BrainAccessFilter` supports `path: :via_brain_page` (`exists(brain_page, brain_id in ^ids)`) and `path: :via_task_brain_page` (`exists(task.brain_page, brain_id in ^ids)`). These are consumed by every Plan-domain policy in A2.

- [ ] **Step 1: Compare cloud vs OSS for both files.** Read `…/brain-plans-src/lib/magus/brain/page.ex` and the OSS `lib/magus/brain/page.ex`; identify the `kind` attribute block, its `constraints one_of: [:page, :plan]`, the promote/demote `update` action (cloud page.ex ~line 209, ~504-508), and any frontmatter `kind` handling. Same for `brain_access_filter.ex` (the `:via_brain_page` + `:via_task_brain_page` clauses).
- [ ] **Step 2: Write the failing test** `test/magus/brain/page_kind_test.exs`: create a page (defaults `kind: :page`), promote it to `:plan`, assert `kind == :plan`; assert demote back to `:page`. Use the OSS magus brain test convention (read an existing `test/magus/brain/*_test.exs` for setup: `Magus.ResourceCase` or `DataCase` + the brain/page generators).
- [ ] **Step 3: Run it -> FAIL** (`kind` unknown). Env-prefixed: `MIX_ENV=test mix test test/magus/brain/page_kind_test.exs`.
- [ ] **Step 4: Merge the `kind` attribute + promote/demote into `page.ex`** (copy the exact blocks from the cloud page.ex; keep `one_of: [:page, :plan]` for now, `:spec` is added in B1). Add the `:via_brain_page` + `:via_task_brain_page` paths to `brain_access_filter.ex` (copy the clauses verbatim).
- [ ] **Step 5: Generate + run the migration.** `mix ash.codegen add_page_kind` then `MIX_ENV=test mix ash.migrate`. Confirm the migration only adds the `kind` column (nullable or with `:page` default) to the pages table.
- [ ] **Step 6: Run the test -> PASS** + `MIX_ENV=test mix compile --warnings-as-errors`.
- [ ] **Step 7: Commit** `lib/magus/brain/page.ex lib/magus/brain/checks/brain_access_filter.ex priv/repo/migrations priv/resource_snapshots test/magus/brain/page_kind_test.exs` — `feat(brain): page :plan kind + brain-access paths for plan tasks`.

### Task 2: [A2] Port the Plan domain (resources + changes + checks + errors)

**Files:**
- Replace/Create: all of `lib/magus/plan/**` from the cloud src (24 files; see the file-disposition map)
- (No test changes here; tests come in A4)

**Interfaces:**
- Consumes: A1's `kind` + access-filter paths.
- Produces: the full ported domain - `Magus.Plan.Task` (conversation OR `brain_page` container; priority; `claimed_at`; `lease_expires_at`; `created_by_label`; subtasks; `ready`/`priority_rank`/`is_stale` calcs; `subtask_count`/`completed_subtask_count`/`open_dependencies_count` aggregates; actions `:create`/`:create_plan`/`:update`/`:claim`/`:release`/`:heartbeat`/`:complete`/`:archive`/`:dismiss`/`:reap_expired_claims`/`:for_conversation`/`:for_plan`/`:ready_for_plan`/`:for_brain`/`:ready_for_brain`/`:stale_claims`/`:open_for_user`), `Magus.Plan.TaskDependency` (+`ValidateAcyclic`), `Magus.Plan.TaskEvent`, the AshOban reaper trigger, and all changes/checks/errors. The domain module `plan.ex` (interfaces + `typescript_rpc`) is included.

- [ ] **Step 1: Copy the whole Plan domain.** `cp -R …/brain-plans-src/lib/magus/plan/. lib/magus/plan/` (this REPLACES the OSS originals — the feature versions are supersets). Verify the 24 files are present (`find lib/magus/plan -type f`).
- [ ] **Step 2: Compile + resolve cloud-only references.** `MIX_ENV=test mix compile 2>&1`. The Plan domain is open-core; expect it to compile clean. If any module references a cloud-only thing (e.g. a `Magus.Billing.*` or a cloud-only helper), STOP and report — do not stub. Likely the only fixes are unused-alias/format. Run `mix format` on `lib/magus/plan/`.
- [ ] **Step 3: Confirm `Magus.Plan` is wired.** `config/config.exs` already lists `Magus.Plan` in `ash_domains` (verified). The domain `plan.ex` registers Task/TaskDependency/TaskEvent/TaskPaneState. Confirm no resource is unregistered (compile will error if so).
- [ ] **Step 4: `MIX_ENV=test mix compile --warnings-as-errors`** -> clean (no migration yet, so DB-touching tests will fail; that is fine here - this task only makes the domain COMPILE).
- [ ] **Step 5: Commit** `lib/magus/plan` — `feat(plan): port brain plans/tasks/coordination domain from cloud branch`.

### Task 3: [A3] Regenerate schema migration + ash_typescript codegen

**Files:**
- Generated: migration(s) for the new `plan_tasks` columns + `plan_task_dependencies` + `plan_task_events` tables; snapshots; `frontend/src/lib/ash/ash_rpc.ts` + `ash_types.ts`

**Interfaces:**
- Consumes: A2 (the resources define the target schema).
- Produces: the DB schema + the generated TS client for the ported RPC actions.

- [ ] **Step 1: Generate the migration.** `mix ash.codegen port_plan_domain`. Review it: it should ALTER `plan_tasks` (add `brain_page_id`, `priority`, `claimed_at`, `lease_expires_at`, `created_by_label`, etc. + the exactly-one-container check constraint) and CREATE `plan_task_dependencies` + `plan_task_events`. No drops of existing data columns.
- [ ] **Step 2: Run it.** `MIX_ENV=test mix ash.migrate`. Re-run -> "already up".
- [ ] **Step 3: Regenerate the TS client.** `mix ash_typescript.codegen`. Confirm `ash_types.ts` gains the Task/TaskEvent/TaskDependency types and `ash_rpc.ts` gains the plan RPC actions. `cd frontend && npm run format`.
- [ ] **Step 4: Smoke.** `MIX_ENV=test mix compile --warnings-as-errors`; a quick `iex`-free read smoke is optional. `cd frontend && npm run check` (the generated TS must typecheck; the hand-written consumers come in A7, so check may report missing consumers - that is fine, focus on the generated files being valid).
- [ ] **Step 5: Commit** `priv/repo/migrations priv/resource_snapshots frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts` — `chore(plan): migration + ash_typescript codegen for ported plan domain`.

### Task 4: [A4] Port + green the Plan domain tests

**Files:**
- Create: `test/magus/plan/**` from cloud src (replace OSS's smaller original plan tests)

**Interfaces:**
- Consumes: A2 + A3.
- Produces: the full Plan domain test suite, green.

- [ ] **Step 1: Copy the tests.** `cp -R …/brain-plans-src/test/magus/plan/. test/magus/plan/`. Also copy any plan-related support (check `…/brain-plans-src/test/support` for plan generators; merge into OSS `test/support` if the generators are missing - diff first, add only the plan/task/brain-page generators the tests need).
- [ ] **Step 2: Run them.** `MIX_ENV=test mix test test/magus/plan/`. Resolve failures from divergence (generator differences, support helpers). Do NOT weaken assertions - fix the support/setup. Expect the reaper-trigger test to use `AshOban.Test.schedule_and_run_triggers`.
- [ ] **Step 3: Green + compile.** All plan tests pass; `MIX_ENV=test mix compile --warnings-as-errors` clean.
- [ ] **Step 4: Commit** `test/magus/plan test/support` — `test(plan): port plan domain tests`.

### Task 5: [A5] Port config (lease, queue, cap)

**Files:**
- Modify: `config/config.exs`

**Interfaces:**
- Produces: `:task_lease_ttl_seconds` (900), `:max_open_tasks_per_plan` (200), the `plan_task_cleanup: 1` Oban queue.

- [ ] **Step 1: Diff the config blocks.** Compare the `config :magus,` block and the `config :magus, Oban, queues:` list between cloud src and OSS. Identify the three additions.
- [ ] **Step 2: Apply additions only.** Add `task_lease_ttl_seconds: 900` + `max_open_tasks_per_plan: 200` to the `config :magus,` block; add `plan_task_cleanup: 1` to the Oban queues. Do NOT touch OSS's `ash_domains` (no `Magus.Billing`).
- [ ] **Step 3: Compile.** `MIX_ENV=test mix compile --warnings-as-errors`. Run the reaper-trigger test from A4 again (it needs the queue): `MIX_ENV=test mix test test/magus/plan/task_reaper_trigger_test.exs`.
- [ ] **Step 4: Commit** `config/config.exs` — `feat(plan): lease TTL + reaper queue + task cap config`.

### Task 6: [A6] Port the API (controllers + router + channel)

**Files:**
- Create: `lib/magus_web/api/v2/tasks_controller.ex`, `lib/magus_web/api/v2/overview_controller.ex`, `lib/magus_web/channels/task_channel.ex`
- Modify: `lib/magus_web/core_router.ex`, `lib/magus_web/channels/user_socket.ex`, (if needed) `lib/magus_web/api/v2/{api_view,controller_helpers}.ex`
- Create: `test/magus_web/api/v2/tasks_controller_test.exs` (+ `overview_controller_test.exs`)

**Interfaces:**
- Consumes: A2 (the domain code interfaces).
- Produces: `/api/v2` task surface (index/create/show/update/claim/release/heartbeat/dependencies) + the brain task overview endpoint + the `task_channel` realtime topics.

- [ ] **Step 1: Copy the new controllers + channel.** `cp` `tasks_controller.ex`, `overview_controller.ex`, `task_channel.ex` from cloud src to the matching OSS paths.
- [ ] **Step 2: Verify the shared helpers.** Confirm OSS `api_view.ex` has `data/1`, `data/2`, `error/2`, `error/3`; `controller_helpers.ex` has `to_atom_map/2`, `ash_errors/1`, `not_found/1`. If any is missing, copy it from the cloud versions (diff first).
- [ ] **Step 3: Merge the routes.** In `lib/magus_web/core_router.ex`, add to the `/api/v2` scope (copy the route lines from the cloud router): `get/post /plans/:plan_id/tasks`, `get/patch /tasks/:id`, `post /tasks/:id/{claim,release,heartbeat}`, `post/delete /tasks/:id/dependencies[/:dep_id]`, and the brain overview route (`get /brains/:brain_id/overview` or as the cloud router names it - match exactly).
- [ ] **Step 4: Register the channel(s).** In `user_socket.ex`, add the `plan_tasks:*` and `brain_tasks:*` channel lines (copy from the cloud user_socket).
- [ ] **Step 5: Copy + run the controller tests.** `cp` `tasks_controller_test.exs` (+ overview) from cloud; `MIX_ENV=test mix test test/magus_web/api/v2/tasks_controller_test.exs test/magus_web/api/v2/overview_controller_test.exs`. Fix divergence (token/auth setup, route paths) without weakening.
- [ ] **Step 6: Green + compile** `--warnings-as-errors`.
- [ ] **Step 7: Commit** the controllers + channel + router + socket + tests + any helper — `feat(api): port /api/v2 plan-task surface + task channel`.

### Task 7: [A7] Port the frontend (board + overview + client)

**Files:**
- Create: `frontend/src/lib/components/plan/**`, `frontend/src/routes/brain/overview/**`, `frontend/src/lib/realtime/task-updates.ts`
- Modify: `frontend/src/lib/ash/api.ts`, `frontend/src/routes/brain/page/[pageId]/+page.svelte`

**Interfaces:**
- Consumes: A3 (generated `ash_rpc.ts`/`ash_types.ts`).
- Produces: the plan board (kanban/list), the brain overview, the realtime task updates, and the `api.ts` task client.

- [ ] **Step 1: Copy the new dirs + file.** `cp -R` `frontend/src/lib/components/plan`, `frontend/src/routes/brain/overview`, and `cp` `frontend/src/lib/realtime/task-updates.ts` from cloud src.
- [ ] **Step 2: Merge `api.ts`.** Add the `PlanTask`, `TaskEventEntry`, `TaskDependencyEntry` types + `TaskStatus`/`TaskPriority`/`TaskEventKind` + the RPC wrapper functions + `PLAN_TASK_FIELDS` from the cloud `api.ts` (diff cloud-vs-OSS; add only the task-related exports).
- [ ] **Step 3: Merge the brain page route.** In `frontend/src/routes/brain/page/[pageId]/+page.svelte`, add the `{#if pageData.kind === 'plan'}` board mount (copy the relevant block + the import of `plan-board.svelte`).
- [ ] **Step 4: Verify + build.** `cd frontend && npm run check` (0 errors) `&& npm run build`. Copy + run the frontend unit tests: `npx vitest run src/lib/components/plan`. If the plan E2E specs (`frontend/tests/plan-board.spec.ts`, `brain-overview.spec.ts`) exist in cloud, copy them and run `npx playwright test plan-board brain-overview`.
- [ ] **Step 5: Commit** the frontend files + tests — `feat(spa): port plan board + brain overview + task client`.

---

## Phase B: Project-state layer (new)

### Task 8: [B1] Page `:spec` kind + spec↔plan link

**Files:**
- Modify: `lib/magus/brain/page.ex` (extend `kind` enum; add `spec_page_id`)
- Generated: migration (`spec_page_id` column) + snapshot
- Test: `test/magus/brain/page_spec_link_test.exs`

**Interfaces:**
- Consumes: A1 (`kind` attribute).
- Produces: `kind` accepts `:spec`; `Page` has `belongs_to :spec_page, Magus.Brain.Page` (`spec_page_id`, nullable) with a reverse `has_many :implementing_plans`. A read `:plans_for_spec` (pages where `spec_page_id == ^arg`).

- [ ] **Step 1: Write the failing test.** `test/magus/brain/page_spec_link_test.exs`: create a `:spec` page and a `:plan` page; set the plan's `spec_page_id` to the spec; assert the plan loads its `spec_page`, and the spec lists the plan via `:plans_for_spec`. (Match OSS brain test conventions.)
- [ ] **Step 2: Run -> FAIL.**
- [ ] **Step 3: Implement.** In `page.ex`: change `kind` constraints to `one_of: [:page, :plan, :spec]`; add `belongs_to :spec_page, Magus.Brain.Page do allow_nil? true; public? true end` (this creates `spec_page_id`); add `has_many :implementing_plans, Magus.Brain.Page do destination_attribute :spec_page_id end`; add a read `:plans_for_spec` (`argument :spec_page_id`; `filter expr(spec_page_id == ^arg(:spec_page_id))`). Allow `spec_page_id` in the relevant update action's accept (or a dedicated `set_spec` update). Keep promote/demote accepting `:spec`.
- [ ] **Step 4: Migration.** `mix ash.codegen add_spec_kind_and_link` + `mix ash.migrate`.
- [ ] **Step 5: Run -> PASS** + compile `--warnings-as-errors`.
- [ ] **Step 6: Commit** `lib/magus/brain/page.ex priv/repo/migrations priv/resource_snapshots test/magus/brain/page_spec_link_test.exs` — `feat(brain): :spec page kind + spec->plan link`.

### Task 9: [B2] Delivery lifecycle on plan pages

**Files:**
- Modify: `lib/magus/brain/page.ex` (add `delivered_at`, `delivery_ref`, `lifecycle` calc, `:stranded_plans` read, `mark_delivered`/`undeliver` actions)
- Create: `lib/magus/brain/page/calculations/lifecycle.ex`
- Generated: migration (`delivered_at`, `delivery_ref`) + snapshot
- Test: `test/magus/brain/page_lifecycle_test.exs`

**Interfaces:**
- Consumes: A2 (Task `status`, the `brain_page` relationship), A1 (`kind`), B1.
- Produces: `Page` attributes `delivered_at :: utc_datetime_usec | nil`, `delivery_ref :: string | nil`; a public calc `lifecycle :: :draft | :active | :done | :delivered`; a read `:stranded_plans` (`argument :brain_id`; plan pages whose lifecycle is `:done`); actions `mark_delivered` (accepts `delivery_ref`, sets `delivered_at` now) and `undeliver` (clears both).

- [ ] **Step 1: Write the failing tests.** `test/magus/brain/page_lifecycle_test.exs`:
  - a `:plan` page with no tasks + no child phases -> `lifecycle == :draft`.
  - a plan with one `:open` task -> `:active`.
  - a plan with all non-cancelled tasks `:done` (and no incomplete child phases) -> `:done`.
  - that same plan after `mark_delivered` -> `:delivered`; `undeliver` -> back to `:done`.
  - a plan with all direct tasks done but a child phase (nested `:plan` page) still `:active` -> `:active` (recursion).
  - `:stranded_plans` for a brain returns the `:done`-but-not-delivered plans, excludes `:delivered` and `:active`.
- [ ] **Step 2: Run -> FAIL.**
- [ ] **Step 3: Implement the lifecycle calc** `lib/magus/brain/page/calculations/lifecycle.ex` (a module calc; loads the page's direct tasks + child `:plan` pages). Logic:
  ```elixir
  defmodule Magus.Brain.Page.Calculations.Lifecycle do
    use Ash.Resource.Calculation
    @impl true
    def load(_q, _opts, _ctx), do: [:delivered_at, :kind, tasks: [:status], child_plan_pages: [:lifecycle]]
    @impl true
    def calculate(pages, _opts, _ctx) do
      Enum.map(pages, fn page ->
        cond do
          not is_nil(page.delivered_at) -> :delivered
          done?(page) -> :done
          active?(page) -> :active
          true -> :draft
        end
      end)
    end
    defp done?(page) do
      tasks = Enum.reject(page.tasks || [], &(&1.status == :cancelled))
      phases = page.child_plan_pages || []
      (tasks != [] or phases != []) and
        Enum.all?(tasks, &(&1.status == :done)) and
        Enum.all?(phases, &(&1.lifecycle in [:done, :delivered]))
    end
    defp active?(page) do
      Enum.any?(page.tasks || [], &(&1.status in [:in_progress, :done])) or
        Enum.any?(page.child_plan_pages || [], &(&1.lifecycle != :draft))
    end
  end
  ```
  NOTE: confirm the relationship names. `tasks` = `has_many` of `Magus.Plan.Task` on `brain_page_id` (add it to `page.ex` if absent: `has_many :tasks, Magus.Plan.Task do destination_attribute :brain_page_id end`). `child_plan_pages` = child pages filtered to `kind: :plan` (add `has_many :child_plan_pages, __MODULE__ do destination_attribute :parent_id; filter expr(kind == :plan) end`). Recursion via `child_plan_pages: [:lifecycle]` load works because `lifecycle` is itself the calc.
- [ ] **Step 4: Add the attributes + calc + read + actions to `page.ex`.** `delivered_at`/`delivery_ref` attributes (nullable, public); `calculate :lifecycle, :atom, {Magus.Brain.Page.Calculations.Lifecycle, []} do public? true end`; `update :mark_delivered do accept [:delivery_ref]; change set_attribute(:delivered_at, &DateTime.utc_now/0) end`; `update :undeliver do accept []; change set_attribute(:delivered_at, nil); change set_attribute(:delivery_ref, nil) end`; `read :stranded_plans do argument :brain_id, :uuid; filter expr(brain_id == ^arg(:brain_id) and kind == :plan and lifecycle == :done) end`. Add code interfaces in the Brain domain.
- [ ] **Step 5: Migration.** `mix ash.codegen add_plan_delivery` + `mix ash.migrate`.
- [ ] **Step 6: Run -> PASS** + compile `--warnings-as-errors`.
- [ ] **Step 7: Commit** the page changes + calc + migration + snapshot + test — `feat(brain): plan delivery lifecycle + stranded-plan detector`.

### Task 10: [B3] Lifecycle + stranded + spec-link API

**Files:**
- Modify: `lib/magus_web/api/v2/tasks_controller.ex` OR a new `lib/magus_web/api/v2/plans_controller.ex` (plan lifecycle endpoints); router
- Test: `test/magus_web/api/v2/plan_lifecycle_test.exs`

**Interfaces:**
- Consumes: B1, B2.
- Produces: `POST /api/v2/plans/:id/deliver` (body `delivery_ref?`) -> marks delivered; `POST /api/v2/plans/:id/undeliver`; `GET /api/v2/brains/:brain_id/stranded` -> done-but-not-delivered plans; `GET /api/v2/plans/:id` includes `lifecycle` + `delivered_at` + `delivery_ref`; spec-link set/read.

- [ ] **Step 1: Write the failing controller tests** (ConnCase + `/api/v2` token, plain string paths): deliver -> 200 + `lifecycle: "delivered"`; undeliver -> `"done"`; stranded -> returns the done-but-not-delivered plan, excludes delivered.
- [ ] **Step 2: Run -> FAIL.**
- [ ] **Step 3: Implement** the controller actions (delegate to the B2 code interfaces; authorize via the page's brain access + `RequireWorkspaceMatch` like tasks_controller) + the routes.
- [ ] **Step 4: Run -> PASS** + compile. `mix ash_typescript.codegen` if any rpc/public attr changed; commit generated TS if so.
- [ ] **Step 5: Commit** — `feat(api): plan delivery + stranded-plan endpoints`.

### Task 11: [B4] Frontend - lifecycle badges, stranded section, unified tree

**Files:**
- Create: `frontend/src/lib/components/plan/lifecycle-badge.svelte`, `frontend/src/lib/components/plan/plan-tree.svelte`
- Modify: `frontend/src/routes/brain/overview/+page.svelte` (+ store) for the stranded section; `frontend/src/lib/ash/api.ts` (lifecycle/stranded wrappers); regenerate TS for the new Page fields
- Test: `frontend/src/lib/components/plan/plan-tree.test.ts` (+ store test)

**Interfaces:**
- Consumes: A7 (board/overview), B2/B3 (lifecycle data + endpoints).
- Produces: a `lifecycle-badge` (draft/active/done/delivered, tokenized: delivered=success, done=warning to signal "not yet delivered", active=primary, draft=muted); a `plan-tree` view (spec -> plan -> phases -> tasks with ready/blocked + lifecycle + the done-but-not-delivered flag); a stranded-work section in the overview.

- [ ] **Step 1: Write the failing unit test** for the tree store / data shaping (the recursive plan->phases->tasks assembly + the stranded flag derivation), Svelte-5-runes + vitest.
- [ ] **Step 2: Run -> FAIL.**
- [ ] **Step 3: Implement** `lifecycle-badge.svelte`, `plan-tree.svelte` (renders the chain; tokens only; no em dashes; no side-stripes), the overview stranded section, and the `api.ts` wrappers. Regenerate `ash_types.ts` (Page now has `lifecycle`/`deliveredAt`/`deliveryRef`) via `mix ash_typescript.codegen` + `npm run format`.
- [ ] **Step 4: Verify.** `npm run check` (0) + `npm run build` + `npx vitest run src/lib/components/plan`.
- [ ] **Step 5: Commit** — `feat(spa): plan lifecycle badges, stranded-work section, unified plan tree`.

---

## Phase C: Verification

### Task 12: [C1] Full verification at HEAD

- [ ] **Step 1: Full backend suite.** `MIX_ENV=test mix test` (env-prefixed). Record results. The requirement: `test/magus/plan/`, `test/magus/brain/`, `test/magus_web/api/v2/` all green; any other failure must be confirmed PRE-EXISTING on OSS magus main (compare against a `git stash` + main run if unsure) and NOT caused by this branch.
- [ ] **Step 2: Compile + frontend.** `MIX_ENV=test mix compile --warnings-as-errors`; `cd frontend && npm run check && npm run build && npx vitest run`; `npx playwright test plan-board brain-overview` (if specs present).
- [ ] **Step 3: Codegen drift check.** `mix ash.codegen --check` (migrations only - OSS magus may expect this to pass) and confirm no uncommitted generated TS (`git status`). Commit any stragglers.
- [ ] **Step 4: Report** the full matrix (backend suite count + any pre-existing failures named, frontend check/build/vitest/e2e). This is the controller's gate before the PR.

---

## Self-Review (completed during planning)

**Spec coverage:** Hierarchy (A1 kind, A2 tasks, B1 spec) ✓; phases = nested :plan (A2 tasks attach to any plan page; B2 recursion) ✓; deps DAG + ready (A2) ✓; lease/reaper plan-task-scoped (A2 + Global Constraints) ✓; delivery lifecycle + done-auto/delivered-explicit + stranded detector (B2) ✓; spec↔plan link (B1) ✓; views: board+overview (A7), tree+stranded+badges (B4) ✓; API: ported (A6) + lifecycle/stranded (B3) ✓; regenerate migrations+codegen here (A3, A5, B steps, C3) ✓; out-of-scope honored (no orchestrator guardrails, no git-merge auto-detect) ✓.

**Placeholder scan:** Port tasks reference exact cloud source paths (the code is real, at a named path) + concrete merge specifics; new-layer tasks carry real Ash/Svelte code. The lifecycle calc is complete code. No TBD/TODO.

**Type/consistency:** `lifecycle` values `:draft|:active|:done|:delivered` consistent across B2/B3/B4; `stranded` = `lifecycle == :done` consistent; `kind` `:page|:plan|:spec` consistent (A1 adds :plan, B1 adds :spec); relationship names (`tasks`, `child_plan_pages`, `spec_page`/`implementing_plans`) consistent B1/B2.

**Risk note for the executor:** the deepest divergence is `brain/page.ex` (OSS has no `kind` at all). A1 must land before A2 (the Plan policies reference the page). If a ported Plan module references a brain helper OSS lacks, port that helper too (diff-driven), but do not pull in cloud-only (billing) code.
