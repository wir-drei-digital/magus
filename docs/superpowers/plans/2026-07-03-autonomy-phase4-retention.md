# Event-Driven Autonomy Phase 4: Retention — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The autonomy tables stop growing unboundedly: inbox events expire on schedule and terminal rows are pruned; orphaned IntegrationConversation mappings are cleaned up.

**Architecture:** ash_oban triggers per resource (established pattern on this branch: `AgentRun.cleanup_stale_runs`, `Credential.warn_expiring`), plus destroy-cascade changes for IntegrationConversation. Spec: `docs/superpowers/specs/2026-07-03-event-driven-agent-autonomy-design.md` §8.

**Tech Stack:** Elixir/Phoenix, Ash 3.x + AshPostgres + ash_oban, ExUnit + `Magus.Generators`.

## Global Constraints

- Never `mix ash.reset`. Codegen + migrate BOTH dev and test partition (`MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix ash.migrate`, env sourced).
- All test commands: `set -a && source .env && set +a && MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test <path>`.
- Retention windows (exact): inbox events — terminal (`resolved|dismissed|expired`) older than 30 days; AgentRun — terminal (`complete|error|timed_out|cancelled|budget_exceeded`) older than 90 days; AgentActivityLog — older than 90 days. Age measured on `updated_at` for events/runs (terminal timestamp proxy) and `inserted_at` for activity logs.
- Expiry enforcement: events with `expires_at < now` and status in `[:pending, :waiting, :processing]` → existing `:expire` action; hourly cron.
- Prune crons: daily, staggered (`"30 4 * * *"` events, `"40 4 * * *"` runs, `"50 4 * * *"` activity logs).
- Destroy semantics: verify FK behavior before destroying runs — `agent_inbox_events.agent_run_id` has `on_delete: :nilify` (agent_inbox_event.ex postgres block); check for OTHER tables referencing agent_runs (grep migrations/resources for `agent_run`) and confirm each has a safe on_delete or exclude blocking cases in the filter.
- Every trigger mirrors the established pattern: own worker/scheduler module names, `max_attempts 1`, `read_action` + `worker_read_action`, `where expr(...)` on a private calculation. Policy bypass `AshOban.Checks.AshObanInteraction` where the resource's policies would block (AgentInboxEvent and AgentRun already have bypasses — verify; add where missing).
- Commit per task with explicit paths after `--`.

---

### Task 1: Retention + expiry triggers

**Files:**
- Modify: `lib/magus/agents/agent_inbox_event.ex` (calcs `is_expiry_due` + `is_prunable`, read actions `:expiry_due` + `:prunable`, destroy action `:prune`, oban triggers `:expire_due_events` (hourly, action `:expire`) + `:prune_terminal_events` (daily))
- Modify: `lib/magus/agents/agent_run.ex` (calc `is_prunable`, read `:prunable_runs`, destroy `:prune`, trigger `:prune_terminal_runs`)
- Modify: `lib/magus/agents/agent_activity_log.ex` (calc, read, destroy, trigger `:prune_old_logs`)
- Test: `test/magus/agents/retention_test.exs` (new)

**Interfaces:** none consumed beyond existing actions; produces the triggers only.

- [ ] **Step 1: Write failing tests.** For each resource: seed rows in-window and out-of-window (backdate `updated_at`/`inserted_at` via `Repo.update_all` — note `updated_at` is touched by any update, so backdate AFTER reaching terminal state), invoke the trigger's update/destroy action directly (pattern: `Ash.Changeset.for_update/for_destroy(..., %{}, authorize?: false)` — see `test/magus/agents/agent_run/sweep_stuck_pending_test.exs` for the established invocation style), assert: expiry-due pending event becomes `:expired`; 31-day-old resolved event deleted, 29-day-old kept, PENDING old event kept (never prune non-terminal); 91-day-old complete run deleted with linked event's `agent_run_id` nilified (create event linked to it first — proves FK nilify), 89-day-old kept, old RUNNING run kept; 91-day-old activity log deleted. Also assert read-action selection lists (in/out) like sweep_stuck_pending_test does.

- [ ] **Step 2: Verify failures.**

- [ ] **Step 3: Implement.** Destroy triggers on ash_oban: the trigger `action` can be a destroy action (verify in deps/ash_oban/usage-rules.md; if destroy actions are unsupported by the trigger DSL, use an update-action wrapper whose change destroys the record — but check docs FIRST, ash_oban supports destroy actions via `action_type` detection). Calc examples:

```elixir
# AgentInboxEvent
calculate :is_expiry_due, :boolean do
  public? false
  calculation expr(
    not is_nil(expires_at) and expires_at < now() and
      status in [:pending, :waiting, :processing]
  )
end

calculate :is_prunable, :boolean do
  public? false
  calculation expr(status in [:resolved, :dismissed, :expired] and updated_at < ago(30, :day))
end
```

Run prunable calc: `status in [:complete, :error, :timed_out, :cancelled, :budget_exceeded] and updated_at < ago(90, :day)`. Activity log: `inserted_at < ago(90, :day)`.

Before finalizing the run prune: `grep -rn "agent_run" priv/resource_snapshots lib --include="*.ex" | grep -i "belongs_to\|references"` — for every FK into agent_runs confirm nilify/cascade or filter those rows out; document findings in the report.

- [ ] **Step 4: codegen (`mix ash.codegen retention_triggers`) — expect trigger bookkeeping only; migrate both DBs if generated. Run tests + compile warnings-as-errors.**

- [ ] **Step 5: Commit** — `feat(agents): retention triggers for inbox events, runs, and activity logs`.

---

### Task 2: IntegrationConversation orphan cleanup

**Files:**
- Modify: `lib/magus/integrations/integration_conversation.ex` and/or the resources that orphan it
- Test: `test/magus/integrations/integration_conversation_cleanup_test.exs` (new)

**Interfaces:** none new.

- [ ] **Step 1: Read first.** `lib/magus/integrations/integration_conversation.ex` — its FKs (integration_id → UserIntegration, conversation_id → Conversation) and their `references` on_delete settings in the postgres block + actual migration. Then determine the two orphan paths: (a) UserIntegration destroy/deactivate; (b) Conversation delete. If the DB already cascades deletes (check migrations for `on_delete: :delete_all` on those FKs), rows only orphan on DEACTIVATION (status change, no destroy) — in that case decide with this rule: deactivation should NOT delete mappings (reactivation should resume existing conversations; the mapping is not garbage while the integration row exists); the real garbage cases are hard deletes, which cascades may already cover. Whatever you find, make the report state precisely which orphan paths existed and which needed code.

- [ ] **Step 2: Failing tests** for each path that needs code: destroy a UserIntegration → its IntegrationConversation rows gone; destroy a Conversation → mapping rows gone. If DB cascades already cover a path, write the test anyway as a pin (it passes immediately — mark it clearly as a regression pin, not TDD) and only add code where a path is uncovered.

- [ ] **Step 3: Implement** missing paths as `change` modules on the destroy actions (after_action destroy of mappings, mirroring `DestroyResourceGrants`-style cleanup changes referenced in CLAUDE.md) or DB reference fixes via codegen if the resources lack `references` declarations (prefer the DB-level fix: declare `reference :..., on_delete: :delete_all` in the postgres block + migration; it covers all future delete paths).

- [ ] **Step 4: Run `test/magus/integrations` + compile; codegen + migrate both DBs if references changed.**

- [ ] **Step 5: Commit** — `feat(integrations): integration-conversation mappings clean up with their parents`.

---

### Task 3: Phase 4 verification sweep

- [ ] `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors` then full `MIX_TEST_PARTITION=_wtevtdrvn MIX_ENV=test mix test test/magus/agents test/magus/integrations test/magus/plan` — 0 failures; `mix format --check-formatted`.
