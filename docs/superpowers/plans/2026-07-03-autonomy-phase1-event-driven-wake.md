# Event-Driven Autonomy Phase 1: Urgent Wake Path — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `:immediate` inbox events wake their agent within seconds instead of waiting up to 6 hours for the heartbeat; the heartbeat becomes a fallback timer.

**Architecture:** A new `AgentRun` source `:inbox_urgent` reuses the entire existing orchestration path (gates, idempotency, claiming, completion). A new Ash change on `AgentInboxEvent :create` enqueues that run in `after_transaction`. The completion plugin drains remaining `:immediate` events before an autonomous run goes back to sleep. Spec: `docs/superpowers/specs/2026-07-03-event-driven-agent-autonomy-design.md` §1–§3.

**Tech Stack:** Elixir/Phoenix, Ash 3.x (resources + code interfaces), Jido plugins, ExUnit with `Magus.Generators`.

## Global Constraints

- Never run `mix ash.reset`. New migrations via `mix ash.codegen <name>` only.
- All test commands from the worktree root with env: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`.
- Call domain code interfaces (`Magus.Agents.xxx/2`), not `Ash.read/4`, except inside internal modules that already use `Ash.Query` directly.
- `require Ash.Query` before `Ash.Query.filter/2`.
- Internal orchestration reads/writes use `authorize?: false` (existing convention in RunOrchestrator/HeartbeatScheduler).
- Idempotency key for urgent wakes is exactly `"inbox:#{event.id}"`. Enum value is exactly `:inbox_urgent`.
- Test fixtures: `use Magus.DataCase` + `import Magus.Generators`; `user = generate(user())`, `agent = generate(custom_agent(user, %{...}))` (see `test/support/generators.ex:936`).
- Existing test files to mirror style from: `test/magus/agents/run_orchestrator_test.exs`, `test/magus/agents/agent_inbox_event_test.exs`, `test/magus/agents/plugins/agent_run_completion_inbox_test.exs`.
- Commit after each task: `git commit -m "<type>(agents): <what>" -- <files>` (explicit paths).

---

### Task 1: `:inbox_urgent` run source + orchestrator gates

**Files:**
- Modify: `lib/magus/agents/agent_run.ex:236-242` (source enum)
- Modify: `lib/magus/agents/run_orchestrator.ex:81-156` (three gates)
- Test: `test/magus/agents/run_orchestrator_test.exs` (extend)

**Interfaces:**
- Consumes: existing `RunOrchestrator.enqueue_with_outcome/1`.
- Produces: `source: :inbox_urgent` accepted by `AgentRun` `:create`; the in-flight gate, daily-run budget, and spend budget all treat `:inbox_urgent` like `:heartbeat`. Later tasks rely on `enqueue_with_outcome(%{source: :inbox_urgent, ...})` returning `{:ok, :created | :existing, run}` or `{:error, :already_running | :budget_exceeded | :insufficient_spend_budget}`.

- [ ] **Step 1: Write the failing tests**

Append to `test/magus/agents/run_orchestrator_test.exs` (inside the existing top-level describe structure, reusing its fixture setup — read the file's `setup` block first and reuse its user/agent/conversation helpers):

```elixir
describe "inbox_urgent source" do
  test "enqueues an :inbox_urgent run", %{...} do
    # build attrs exactly like an existing :heartbeat enqueue test in this
    # file, but with source: :inbox_urgent and
    # idempotency_key: "inbox:#{Ash.UUID.generate()}"
    assert {:ok, :created, run} = RunOrchestrator.enqueue_with_outcome(attrs)
    assert run.source == :inbox_urgent
  end

  test "in-flight gate rejects :inbox_urgent when a :heartbeat run is pending" do
    # enqueue a :heartbeat run for the agent first (as existing tests do),
    # then:
    assert {:error, :already_running} =
             RunOrchestrator.enqueue_with_outcome(%{attrs | source: :inbox_urgent,
               idempotency_key: "inbox:#{Ash.UUID.generate()}"})
  end

  test "in-flight gate rejects :heartbeat when an :inbox_urgent run is pending" do
    # inverse of the above
  end

  test ":inbox_urgent runs count toward max_daily_runs" do
    # agent with max_daily_runs: 1; create one COMPLETED :inbox_urgent run
    # for the agent (via Magus.Agents.create_agent_run + complete_agent_run,
    # authorize?: false — a completed run does not trip the in-flight gate
    # but must still consume the daily budget), then a :heartbeat enqueue
    # must return {:error, :budget_exceeded}
  end
end
```

Replace the `...`/comments with concrete code following the file's existing patterns — every test must construct real attrs maps.

- [ ] **Step 2: Run tests to verify they fail**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/run_orchestrator_test.exs`
Expected: FAIL — `atom :inbox_urgent` rejected by attribute `one_of` constraint.

- [ ] **Step 3: Implement**

In `lib/magus/agents/agent_run.ex` (~line 237):

```elixir
constraints one_of: [:mention, :heartbeat, :manual_trigger, :sub_agent_spawn, :inbox_urgent]
```

In `lib/magus/agents/run_orchestrator.ex`:

```elixir
@autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]

defp check_no_in_flight_autonomous_run(%{source: source, target_agent_id: agent_id})
     when source in @autonomous_sources and not is_nil(agent_id) do
  in_flight =
    AgentRun
    |> Ash.Query.filter(
      target_agent_id == ^agent_id and
        source in ^@autonomous_sources and
        status in [:pending, :running]
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)

  case in_flight do
    [] -> :ok
    [_ | _] -> {:error, :already_running}
  end
end
```

Budget gates: change `check_daily_run_budget/1` head to match `%{source: source, target_agent_id: agent_id} when source in [:heartbeat, :inbox_urgent]`, and inside `evaluate_daily_run_budget/2` change the count filter to `source in [:heartbeat, :inbox_urgent]`. Change `check_owner_spend_budget/1` head to match `%{source: source, initiator_user_id: user_id} when source in [:heartbeat, :inbox_urgent]`. (`:manual_trigger` keeps its current budget exemptions — do not add it to the budget gates.) Update the module comment block at lines 67–79 to describe the new source.

Note: `Ash.Query.filter(source in ^@autonomous_sources)` requires the pin; module attributes cannot be used unpinned inside the filter macro.

- [ ] **Step 4: Check codegen is a no-op, run tests**

Run: `set -a && source .env && set +a && mix ash.codegen add_inbox_urgent_source --check`
Expected: no migrations needed (atom attrs are text columns). If it DOES generate a migration, run `mix ash.codegen add_inbox_urgent_source` for real, inspect it (it must only touch check constraints for agent_runs.source), and `mix ash.migrate`.

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/run_orchestrator_test.exs test/magus/agents/agent_run_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): add :inbox_urgent run source with heartbeat-equivalent gates" -- lib/magus/agents/agent_run.ex lib/magus/agents/run_orchestrator.ex test/magus/agents/run_orchestrator_test.exs priv/repo/migrations
```

---

### Task 2: `HeartbeatEventMessage` support for `:inbox_urgent`

**Files:**
- Modify: `lib/magus/agents/heartbeat_event_message.ex`
- Test: `test/magus/agents/heartbeat_event_message_test.exs` (extend)

**Interfaces:**
- Consumes: existing `HeartbeatEventMessage.create(home_conversation_id, run_id: run.id, source: :heartbeat)` and `HeartbeatEventMessage.transition(msg, stage, data)`.
- Produces: `HeartbeatEventMessage.create(home_id, run_id: run.id, source: :inbox_urgent)` works and renders a distinct label. Task 3 calls exactly this.

- [ ] **Step 1: Read the module, write the failing test**

Read `lib/magus/agents/heartbeat_event_message.ex` fully. It validates/renders per source (`:heartbeat` → "Heartbeat started…", `:manual_trigger` → "Manual wake-up…"). Add a test to `test/magus/agents/heartbeat_event_message_test.exs` mirroring an existing `create/2` test but with `source: :inbox_urgent`, asserting the message text contains `"urgent"` (case-insensitive) and metadata `"source" => "inbox_urgent"` (match the exact metadata key format the module already writes — check whether it stores `:heartbeat` as atom or string and follow suit).

- [ ] **Step 2: Run test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/heartbeat_event_message_test.exs`
Expected: FAIL (unknown source / FunctionClauseError).

- [ ] **Step 3: Implement**

Add `:inbox_urgent` wherever the module enumerates sources. Starting-message copy: `"Woken by urgent inbox event at <time>"`, matching the phrasing/format of the existing heartbeat copy (reuse the same time-formatting helper). Terminal stages need no new variants.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/heartbeat_event_message_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): inbox_urgent wake-up trace messages" -- lib/magus/agents/heartbeat_event_message.ex test/magus/agents/heartbeat_event_message_test.exs
```

---

### Task 3: `TriggerUrgentWake` change on event creation

**Files:**
- Create: `lib/magus/agents/agent_inbox_event/changes/trigger_urgent_wake.ex`
- Modify: `lib/magus/agents/agent_inbox_event.ex:42-70` (`:create` action only — NOT `:create_waiting`)
- Test: `test/magus/agents/trigger_urgent_wake_test.exs` (new)

**Interfaces:**
- Consumes: `RunOrchestrator.enqueue_with_outcome/1` (Task 1), `HeartbeatEventMessage.create/2` (Task 2), `Magus.Agents.link_event_to_run(event, run_id, authorize?: false)` (existing code interface used by `lib/magus/agents/tools/autonomy/link_inbox_event.ex`), `Magus.Agents.Support.HomeConversation.ensure(user_id, agent_id)`.
- Produces: creating an `AgentInboxEvent` via the `:create` action with `urgency: :immediate` enqueues one `:inbox_urgent` run. Task 7 (approval events) and Task 8 (integrations) rely on this behavior with zero extra wiring.

- [ ] **Step 1: Write the failing tests**

Create `test/magus/agents/trigger_urgent_wake_test.exs`:

```elixir
defmodule Magus.Agents.TriggerUrgentWakeTest do
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Agents.AgentRun

  setup do
    user = generate(user())
    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: false}))
    %{user: user, agent: agent}
  end

  defp create_event(user, agent, attrs) do
    base = %{
      agent_id: agent.id,
      event_type: :task_assigned,
      urgency: :immediate,
      title: "Test urgent event",
      source_type: :system
    }

    Magus.Agents.create_inbox_event(Map.merge(base, attrs), actor: user)
  end

  defp runs_for(agent) do
    AgentRun
    |> Ash.Query.filter(target_agent_id == ^agent.id and source == :inbox_urgent)
    |> Ash.read!(authorize?: false)
  end

  test "immediate event enqueues an :inbox_urgent run pre-linked to the event",
       %{user: user, agent: agent} do
    {:ok, event} = create_event(user, agent, %{})

    assert [run] = runs_for(agent)
    assert run.idempotency_key == "inbox:#{event.id}"
    assert run.initiator_user_id == user.id

    event = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
    assert event.agent_run_id == run.id
  end

  test "deferred event does not enqueue", %{user: user, agent: agent} do
    {:ok, _} = create_event(user, agent, %{urgency: :deferred})
    assert runs_for(agent) == []
  end

  test "paused agent does not wake", %{user: user} do
    agent = generate(custom_agent(user, %{heartbeat_enabled: true, is_paused: true}))
    {:ok, _} = create_event(user, agent, %{})
    assert runs_for(agent) == []
  end

  test "heartbeat-disabled agent does not wake", %{user: user} do
    agent = generate(custom_agent(user, %{heartbeat_enabled: false}))
    {:ok, _} = create_event(user, agent, %{})
    assert runs_for(agent) == []
  end

  test "event created with agent_run_id already set does not wake",
       %{user: user, agent: agent} do
    # simulate an event pre-linked by a run in flight
    {:ok, run} = seed_completed_urgent_run(user, agent)
    {:ok, _} = create_event(user, agent, %{agent_run_id: run.id})
    assert length(runs_for(agent)) == 1  # only the seeded one
  end

  test "in-flight autonomous run: event stays pending, unlinked, no run created",
       %{user: user, agent: agent} do
    # seed a RUNNING :heartbeat run for the agent so the gate rejects
    seed_running_heartbeat_run(user, agent)
    {:ok, event} = create_event(user, agent, %{})

    assert runs_for(agent) == []
    event = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)
    assert event.status == :pending
    assert is_nil(event.agent_run_id)
  end

  test "event creation never fails when enqueue errors", %{user: user, agent: agent} do
    # force enqueue failure by pointing the agent at a user with no home
    # conversation possible — if impractical, instead assert the happy path
    # rescues by deleting the agent's user? Skip if not feasible without
    # mocks; the rescue clause is covered by code review.
    {:ok, _event} = create_event(user, agent, %{})
  end
end
```

`seed_running_heartbeat_run/2` / `seed_completed_urgent_run/2`: create via `Magus.Agents.create_agent_run(%{kind: :delegate, source: :heartbeat, target_agent_id: agent.id, target_conversation_id: <home conv id>, initiator_user_id: user.id, request_id: "hb-#{Ash.UUID.generate()}", objective: "x"}, authorize?: false)` then `Magus.Agents.start_agent_run(run, authorize?: false)` (running) or `complete_agent_run` (completed). Get the home conversation with `Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)`. Delete the last placeholder-ish test if there is no clean way to force an enqueue error — do not mock.

There must also be a check that `Magus.Agents.create_inbox_event/2` exists as a code interface on the domain; if the domain only exposes another name (grep `lib/magus/agents.ex` for `create` + `AgentInboxEvent`), use the existing interface name everywhere in this plan.

- [ ] **Step 2: Run tests to verify they fail**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/trigger_urgent_wake_test.exs`
Expected: FAIL — no run is created (change doesn't exist yet).

- [ ] **Step 3: Implement the change module**

Create `lib/magus/agents/agent_inbox_event/changes/trigger_urgent_wake.ex`:

```elixir
defmodule Magus.Agents.AgentInboxEvent.Changes.TriggerUrgentWake do
  @moduledoc """
  Wakes the owning agent when an `:immediate` inbox event is created.

  Enqueues an `:inbox_urgent` AgentRun through the standard orchestrator
  gates. Runs in `after_transaction` so agent dispatch never happens inside
  the event's insert transaction. Never fails event creation: every error
  path logs and returns the event unchanged.

  Skips: `:deferred` events, paused or heartbeat-disabled agents, and events
  created with `agent_run_id` already set (pre-linked by an in-flight run).
  One urgent run per event, ever: the `"inbox:<event_id>"` idempotency key
  makes replays and post-failure retries no-ops; an unhandled event falls
  back to the next heartbeat.
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.HeartbeatEventMessage
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Support.HomeConversation

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, event} ->
        maybe_wake(event)
        {:ok, event}

      _changeset, error ->
        error
    end)
  end

  defp maybe_wake(%{urgency: :immediate, agent_run_id: nil} = event) do
    with {:ok, agent} <- Ash.get(Magus.Agents.CustomAgent, event.agent_id, authorize?: false),
         true <- agent.heartbeat_enabled and not agent.is_paused,
         {:ok, home} <- HomeConversation.ensure(agent.user_id, agent.id) do
      enqueue(event, agent, home)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning(
        "TriggerUrgentWake: wake failed for event #{event.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp maybe_wake(_event), do: :ok

  defp enqueue(event, agent, home) do
    attrs = %{
      kind: :delegate,
      source: :inbox_urgent,
      source_conversation_id: home.id,
      target_conversation_id: home.id,
      target_agent_id: agent.id,
      initiator_user_id: agent.user_id,
      request_id: "inbox-urgent-#{Ash.UUID.generate()}",
      idempotency_key: "inbox:#{event.id}",
      objective: "Urgent inbox event: #{event.title}"
    }

    case RunOrchestrator.enqueue_with_outcome(attrs) do
      {:ok, :created, run} ->
        link_event(event, run)
        trace(home.id, run)

      {:ok, :existing, _run} ->
        :ok

      {:error, :already_running} ->
        # Drained by AgentRunCompletionPlugin when the in-flight run finishes.
        :ok

      {:error, reason} when reason in [:budget_exceeded, :insufficient_spend_budget] ->
        Logger.info("TriggerUrgentWake: skipped (#{reason}) for event #{event.id}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "TriggerUrgentWake: enqueue failed for event #{event.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp link_event(event, run) do
    case Magus.Agents.link_event_to_run(event, run.id, authorize?: false) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning(
          "TriggerUrgentWake: failed to link event #{event.id} to run #{run.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp trace(home_id, run) do
    case HeartbeatEventMessage.create(home_id, run_id: run.id, source: :inbox_urgent) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("TriggerUrgentWake: trace message failed: #{inspect(reason)}")
        :ok
    end
  end
end
```

Verify `Magus.Agents.link_event_to_run/3` exists (grep `lib/magus/agents.ex` for `link_event_to_run`; it is used by `lib/magus/agents/tools/autonomy/link_inbox_event.ex`). If its signature differs (e.g. takes `%{run_id: ...}` args map), adapt the call.

Wire into the `:create` action in `lib/magus/agents/agent_inbox_event.ex` after the existing `after_action` broadcast (order within the action block; `after_transaction` hooks run after all `after_action` hooks regardless):

```elixir
change Magus.Agents.AgentInboxEvent.Changes.TriggerUrgentWake
```

Do NOT add it to `:create_waiting` (approval-request events are created BY the agent mid-run and must not wake it).

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/trigger_urgent_wake_test.exs test/magus/agents/agent_inbox_event_test.exs`
Expected: PASS, including the pre-existing inbox event tests (deferred default urgency means they don't wake).

Also run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents test/magus/plan`
Expected: PASS except pre-existing baseline failures (`integration_test.exs:195` model-override assertion). NOTE: `NotifyAgentAssignment`/`NotifyTaskCompletion`/`RequestApproval` create `:immediate` events — their tests now exercise TriggerUrgentWake implicitly. If any fail because a run now exists where none was expected, fix the TEST expectation only if the new behavior is spec-correct; never weaken the wake behavior to keep an old test green.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): urgent inbox events wake the agent via :inbox_urgent runs" -- lib/magus/agents/agent_inbox_event/changes/trigger_urgent_wake.ex lib/magus/agents/agent_inbox_event.ex test/magus/agents/trigger_urgent_wake_test.exs
```

---

### Task 4: Completion plugin — drain-before-sleep + `ensure_next_scheduled_at` for `:inbox_urgent`

**Files:**
- Modify: `lib/magus/agents/plugins/agent_run_completion_plugin.ex` (`complete_run/2` ~line 131, `fail_run/2` ~line 172, `ensure_next_scheduled_at/1` ~line 225, `handle_run_completed/1` ~line 155, `handle_run_failed/2` ~line 166)
- Test: `test/magus/agents/plugins/agent_run_completion_inbox_test.exs` (extend)

**Interfaces:**
- Consumes: Task 1 enqueue, Task 3's idempotency-key convention `"inbox:#{event.id}"`, existing `Magus.Agents.list_pending_events!/2` or direct query.
- Produces: `drain_urgent_events(run)` — private; after any autonomous run reaches a terminal state, pending unlinked `:immediate` events get exactly one follow-up `:inbox_urgent` run.

- [ ] **Step 1: Write the failing tests**

Extend `test/magus/agents/plugins/agent_run_completion_inbox_test.exs` (reuse its setup; it already builds runs + events and calls the `handle_run_completed/1` / `handle_run_failed/2` test entry points):

```elixir
describe "drain-before-sleep" do
  test "pending :immediate event enqueues follow-up :inbox_urgent run after heartbeat completes" do
    # 1. agent with heartbeat_enabled: true
    # 2. create a :heartbeat run, mark :complete (Magus.Agents.complete_agent_run)
    # 3. create an :immediate inbox event with agent_run_id: nil,
    #    BYPASSING TriggerUrgentWake wake (simulate arrived-mid-run): create it
    #    while a running heartbeat run exists, so the gate rejected the wake —
    #    or create with urgency :immediate directly and delete the auto-run:
    #    simplest is to seed the event while the heartbeat run is :running,
    #    then complete the run, then:
    AgentRunCompletionPlugin.handle_run_completed(completed_run)
    # 4. assert a new AgentRun exists: source :inbox_urgent,
    #    idempotency_key "inbox:#{event.id}", and event.agent_run_id == new run id
  end

  test "drain does not re-run an event whose urgent run already happened" do
    # event with idempotency key already consumed by a COMPLETED :inbox_urgent
    # run (create run with idempotency_key "inbox:#{event.id}", complete it,
    # unlink event). handle_run_completed(other_run) must NOT create a second
    # run: count runs with that key == 1, event stays :pending.
  end

  test "drain ignores :deferred events" do
  end

  test "drain skips non-autonomous (e.g. :mention) run completions" do
  end

  test "failed autonomous run also drains" do
    # handle_run_failed path: unlink happens first, then drain re-picks the
    # event ONLY IF its key is unused (it was linked to the failed run — key
    # "inbox:#{event.id}" was consumed by that failed run → :existing → no
    # new run). Assert no second run is created for that event.
  end
end

describe "ensure_next_scheduled_at for :inbox_urgent" do
  test "completed :inbox_urgent run schedules fallback heartbeat when none set" do
    # agent with next_scheduled_at: nil; :inbox_urgent run marked complete;
    # handle_run_completed(run); reload agent; assert next_scheduled_at
    # is ~interval minutes in the future.
  end
end
```

Fill in real code following the file's existing helper functions.

- [ ] **Step 2: Run tests to verify they fail**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/plugins/agent_run_completion_inbox_test.exs`
Expected: FAIL — no drain, no fallback scheduling for `:inbox_urgent`.

- [ ] **Step 3: Implement**

In `lib/magus/agents/plugins/agent_run_completion_plugin.ex`:

1. `ensure_next_scheduled_at/1`: change the function head guard from `%{source: :heartbeat, ...}` to `%{source: source, target_agent_id: agent_id} when source in [:heartbeat, :inbox_urgent] and is_binary(agent_id)`.

2. Add the drain step. Insert `drain_urgent_events(completed_run)` in `complete_run/2` immediately BEFORE `ensure_next_scheduled_at(completed_run)`, and `drain_urgent_events(failed_run)` in `fail_run/2` immediately AFTER `unlink_linked_inbox_events(failed_run)`. Mirror both into the `handle_run_completed/1` and `handle_run_failed/2` test entry points (same ordering).

```elixir
@autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]

# After an autonomous run reaches a terminal state, give pending urgent
# events that arrived mid-run (their wake was rejected by the in-flight
# gate) their follow-up run before the agent goes back to sleep. The
# per-event idempotency key caps this at one urgent run per event ever:
# an event whose run already happened resolves to :existing and stays
# pending for the next heartbeat.
defp drain_urgent_events(%{source: source, target_agent_id: agent_id} = run)
     when source in @autonomous_sources and is_binary(agent_id) do
  events =
    Magus.Agents.AgentInboxEvent
    |> Ash.Query.filter(
      agent_id == ^agent_id and
        urgency == :immediate and
        status in [:pending, :waiting] and
        is_nil(agent_run_id)
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)

  case events do
    [event] -> enqueue_urgent_followup(event, run)
    [] -> :ok
  end
rescue
  e ->
    Logger.warning("AgentRunCompletion: drain failed: #{Exception.message(e)}")
    :ok
end

defp drain_urgent_events(_run), do: :ok

defp enqueue_urgent_followup(event, run) do
  attrs = %{
    kind: :delegate,
    source: :inbox_urgent,
    source_conversation_id: run.target_conversation_id,
    target_conversation_id: run.target_conversation_id,
    target_agent_id: run.target_agent_id,
    initiator_user_id: run.initiator_user_id,
    request_id: "inbox-urgent-#{Ash.UUID.generate()}",
    idempotency_key: "inbox:#{event.id}",
    objective: "Urgent inbox event: #{event.title}"
  }

  case RunOrchestrator.enqueue_with_outcome(attrs) do
    {:ok, :created, new_run} ->
      case Magus.Agents.link_event_to_run(event, new_run.id, authorize?: false) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning(
            "AgentRunCompletion: drain link failed for event #{event.id}: #{inspect(reason)}"
          )

          :ok
      end

    {:ok, :existing, _} ->
      :ok

    {:error, reason} ->
      Logger.info("AgentRunCompletion: drain enqueue skipped (#{inspect(reason)})")
      :ok
  end
end
```

Ordering note (important): in `complete_run/2` the drain call must come AFTER `Magus.Agents.complete_agent_run` succeeded (the run is terminal, so the in-flight gate passes) and BEFORE `ensure_next_scheduled_at`. In `fail_run/2` after `fail_agent_run` + `unlink_linked_inbox_events`.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/plugins`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): drain pending urgent events before autonomous runs sleep" -- lib/magus/agents/plugins/agent_run_completion_plugin.ex test/magus/agents/plugins/agent_run_completion_inbox_test.exs
```

---

### Task 5: `WakeupPreamble` for `:inbox_urgent`

**Files:**
- Modify: `lib/magus/agents/context/wakeup_preamble.ex` (build/1 guard ~line 21, header/2 ~line 52)
- Modify: whatever builder passes `source` into the preamble ctx — grep `WakeupPreamble.build` (expected in `lib/magus/agents/context/` or the Preflight/Builder module) and confirm it passes the run source through for `:inbox_urgent` runs; extend its source guard if it filters.
- Test: `test/magus/agents/context/wakeup_preamble_test.exs` (extend; create if missing, mirroring `test/magus/agents/context/` conventions)

**Interfaces:**
- Consumes: run ctx map `%{source: :inbox_urgent, custom_agent: agent, user: user}` (+ whatever the builder already passes).
- Produces: non-empty preamble for `:inbox_urgent` with header `"You were woken by an urgent inbox event."` and the standard inbox/tasks/activity sections + autonomy tools list.

- [ ] **Step 1: Write the failing test**

```elixir
test "builds preamble for :inbox_urgent with urgent header" do
  # mirror an existing :heartbeat build test's ctx construction
  preamble = WakeupPreamble.build(%{ctx | source: :inbox_urgent})
  assert preamble =~ "urgent inbox event"
  assert preamble =~ "list_inbox_events"
end
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `build/1` returns `""` for unknown sources.

- [ ] **Step 3: Implement**

In `wakeup_preamble.ex`: change the guard `when source in [:heartbeat, :manual_trigger]` to include `:inbox_urgent`; add `defp header(:inbox_urgent, _user), do: "You were woken by an urgent inbox event."`. The inbox section already lists pending events sorted urgency-first (`pending_for_agent`), so the triggering event appears at the top naturally — but the linked event has `agent_run_id` set and `status :pending`, confirm `pending_for_agent` still includes it (it filters only on status, so yes).

Then grep for where the preamble is attached (`grep -rn "WakeupPreamble" lib/`) and make the caller include `:inbox_urgent` in any source allowlist it has.

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/context`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): wakeup preamble for urgent inbox wake-ups" -- lib/magus/agents/context/wakeup_preamble.ex test/magus/agents/context
```

(Include the builder file in the commit if it needed a change.)

---

### Task 6: Approval responses create an `:immediate` event

**Files:**
- Modify: `lib/magus/agents/plugins/inbox_event_plugin.ex:164-190` (`check_approval_response/3`)
- Test: `test/magus/agents/plugins/inbox_event_plugin_test.exs` (extend; if approval matching is tested elsewhere, grep `check_approval_response` / `get_waiting_approval` in `test/` and extend that file)

**Interfaces:**
- Consumes: existing approval matching (`get_waiting_approval` + option prefix match), Task 3's TriggerUrgentWake (fires automatically on the new event's creation).
- Produces: on approval match, a new pending `AgentInboxEvent` `event_type: :approval_response, urgency: :immediate` for the agent that asked, carrying the chosen option.

- [ ] **Step 1: Write the failing test**

Mirror the existing approval-matching test setup (waiting event with `payload: %{"options" => ["Approve", "Reject"], "question" => ...}`, `source_id: conversation_id`, agent + user). Then simulate the user message signal that matches `"Approve: ..."` and assert:

```elixir
# the waiting event is resolved (existing behavior, keep asserting it)
# AND a new pending event exists:
new_event =
  Magus.Agents.AgentInboxEvent
  |> Ash.Query.filter(
    agent_id == ^agent.id and event_type == :approval_response and status == :pending
  )
  |> Ash.read_one!(authorize?: false)

assert new_event.urgency == :immediate
assert new_event.idempotency_key == "approval_response:#{waiting_event.id}"
assert new_event.payload["chosen_option"] == "Approve"
assert new_event.payload["response_text"] =~ "Approve:"
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — no new event created.

- [ ] **Step 3: Implement**

In `check_approval_response/3`, inside the `if matched do` block after the existing `resolve_event` call:

```elixir
if matched do
  Magus.Agents.resolve_event(
    event,
    %{resolved_by: :user, resolution_note: "User chose: #{matched}"},
    actor: user
  )

  create_approval_response_event(event, matched, text, user)
end
```

New private function in the same module:

```elixir
# The requesting agent learns of the user's decision via an :immediate
# inbox event, which TriggerUrgentWake turns into an :inbox_urgent run.
defp create_approval_response_event(waiting_event, matched, text, user) do
  attrs = %{
    agent_id: waiting_event.agent_id,
    event_type: :approval_response,
    urgency: :immediate,
    title: "Approval response: #{matched}",
    summary: String.slice(text, 0, 500),
    payload: %{
      "chosen_option" => matched,
      "response_text" => text,
      "question" => waiting_event.payload["question"],
      "source_conversation_id" => waiting_event.source_id,
      "request_event_id" => waiting_event.id
    },
    source_type: :conversation,
    source_id: waiting_event.source_id,
    idempotency_key: "approval_response:#{waiting_event.id}"
  }

  case Magus.Agents.create_inbox_event(attrs, actor: user) do
    {:ok, _} -> :ok
    {:error, reason} ->
      Logger.warning(
        "InboxEventPlugin: approval response event failed: #{inspect(reason)}"
      )

      :ok
  end
end
```

(Use the actual domain code-interface name for inbox event creation discovered in Task 3; keep both call sites consistent.)

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/plugins test/magus/agents/trigger_urgent_wake_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(agents): approval responses wake the requesting agent" -- lib/magus/agents/plugins/inbox_event_plugin.ex test/magus/agents/plugins
```

---

### Task 7: Integration urgency — LogSource criticals are `:immediate`, per-integration override

**Files:**
- Modify: `lib/magus/integrations/providers/log_source.ex:219` (urgency in `build_inbox_event_attrs/2`)
- Modify: `lib/magus/integrations/threshold_checker.ex` (apply override after provider builds attrs)
- Test: `test/magus/integrations/threshold_checker_test.exs` (extend or create; grep `test/magus/integrations/` for existing provider tests and follow their fixture style)

**Interfaces:**
- Consumes: provider callback `build_inbox_event_attrs(integration, entries)` (behaviour in `lib/magus/integrations/providers/data_source_behaviour.ex:64`).
- Produces: LogSource events with any `:critical` entry get `urgency: :immediate`; any data-source integration with `config["urgency_override"]` set to `"immediate"` or `"deferred"` gets that urgency regardless of provider default.

- [ ] **Step 1: Write the failing tests**

```elixir
test "log source with critical entries builds an :immediate event"
# entries list containing one %{severity: :critical, ...} →
# build_inbox_event_attrs urgency == :immediate

test "log source with only :error entries stays :deferred"

test "config urgency_override: 'immediate' promotes an RSS event" do
  # integration with config Map.put(config, "urgency_override", "immediate")
  # ThresholdChecker.check(...) creates event with urgency :immediate
end

test "config urgency_override: 'deferred' demotes a critical log event"
```

Read `lib/magus/integrations/providers/log_source.ex` and `threshold_checker.ex` first; construct entries exactly as `classify/1` outputs them (severity atoms). Reuse the integration fixture from existing integration tests (grep `test/magus/integrations` for `user_integration` setup).

- [ ] **Step 2: Run tests to verify they fail**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/integrations`
Expected: new tests FAIL.

- [ ] **Step 3: Implement**

`log_source.ex` `build_inbox_event_attrs/2`: compute urgency from entries:

```elixir
urgency = if Enum.any?(entries, &(&1[:severity] == :critical or &1["severity"] == :critical)),
  do: :immediate, else: :deferred
```

(match the actual entry key shape used in that module — read how `classify/1` stores severity and use the same access pattern.)

`threshold_checker.ex`: after obtaining `attrs` from `provider.build_inbox_event_attrs/2` and before creating the event:

```elixir
attrs = apply_urgency_override(attrs, integration)

defp apply_urgency_override(attrs, %{config: %{"urgency_override" => "immediate"}}),
  do: Map.put(attrs, :urgency, :immediate)

defp apply_urgency_override(attrs, %{config: %{"urgency_override" => "deferred"}}),
  do: Map.put(attrs, :urgency, :deferred)

defp apply_urgency_override(attrs, _integration), do: attrs
```

- [ ] **Step 4: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/integrations`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(integrations): critical log events are immediate; per-integration urgency override" -- lib/magus/integrations/providers/log_source.ex lib/magus/integrations/threshold_checker.ex test/magus/integrations
```

---

### Task 8: Phase 1 verification sweep

**Files:** none new.

- [ ] **Step 1: Full compile + relevant suites**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents test/magus/integrations test/magus/plan
```

Expected: compile clean; only the pre-existing baseline failures (`test/magus/agents/integration_test.exs:195` and one other pre-existing) — nothing new.

- [ ] **Step 2: Format**

```bash
mix format
git diff --stat  # if format touched files, commit them
```

- [ ] **Step 3: Commit any format fixes**

```bash
git commit -m "chore: format" -- <files>   # only if needed
```
