# Checkpoint-Resume for Agentic Turns Implementation Plan

> **STATUS: DEFERRED (2026-07-08).** After critique (config-fingerprint fragility, write amplification, no coverage for AgentRun-driven turns), the team chose the lightweight alternative first: interrupted turns are re-dispatched with a visible `turn_interrupted` event message and a `recovery_retry` context note telling the model not to redo work whose tool results are already in history (see `Magus.Agents.Dispatcher.dispatch_recovery_retry/1`, `Preflight.maybe_append_recovery_note`, `Recovery.create_interruption_event`). Revisit this plan only if the preamble approach proves insufficient: non-idempotent tool duplication in practice, or models demonstrably redoing expensive completed work.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deploy or crash mid-turn resumes the ReAct run from its last checkpoint instead of re-dispatching the whole turn from scratch.

**Architecture:** The Runner already emits signed checkpoint tokens (`Jido.AI.Reasoning.ReAct.Token.issue/2`, full runtime `State` embedded, config-fingerprint-validated) at every LLM/tool boundary; today they die in parent strategy state. We persist the latest token per conversation in a new `TurnCheckpoint` Postgres resource (written by a new plugin on a new `ai.react.checkpoint` signal, cleared on turn completion), and teach Recovery to redeem it: on thaw, the interrupted message is re-dispatched WITH the token, which flows through InboundPlugin → strategy → worker, where `Token.decode_state/2` rebuilds the runtime state and `Runner.stream_from_state/3` continues the loop. Every failure mode (missing/stale/expired token, config fingerprint mismatch, request_id mismatch) falls back to today's behavior: fresh re-dispatch.

**Tech Stack:** Ash 3.x resource + AshPostgres migration, Jido plugin, existing Runner/worker/strategy modules, ExUnit + Mox.

## Global Constraints

- NEVER run `mix ash.reset` (wipes data). New migrations only; run with `mix ash.migrate` / `MIX_ENV=test mix ash.migrate`.
- Tests run with: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`.
- Compile checks use `MIX_ENV=test mix compile --warnings-as-errors` (never plain `mix compile` while the dev server runs).
- `mix format <files>` before every commit; commit with explicit paths only (`git commit -- <paths>`), the checkout is shared with concurrent sessions.
- Two known pre-existing failures in `test/magus/agents` (InboundPlugin "test-model" assertions) are caused by leaked model rows in the shared test DB; they are NOT yours to fix.
- The upstream ReAct `Event` kind enum is CLOSED (`deps/jido_ai/.../event.ex`): never invent new event kinds; ride data inside existing kinds.
- Explicit `nil` values for optional Zoi-validated payload fields KILL the worker (Zoi rejects nil for typed optionals). Omit keys instead of passing nil.
- The runner context flag convention for wrap-ups is `:__wrap_up_reason__`; internal context keys use dunder naming.

## Design Invariants (read before any task)

- `request_id == message_id` of the driving user message throughout Magus (InboundPlugin sets it), so a checkpoint row stores `request_id` and Recovery correlates it with the interrupted message id directly.
- Resume duplication bounds: a token checkpointed `:after_llm` whose tool round never ran will re-plan (dangling tool_calls are healed, Task 4); a token checkpointed with `status: :awaiting_tools` re-executes at most ONE tool round. Accepted for v1; tool idempotency is out of scope.
- Resumed turns pass `initial_messages` from Preflight as usual. The interrupted attempt's persisted tool-event messages therefore appear both in history and in the checkpointed loop thread. Accepted redundancy for v1 (correctness over token efficiency); do not try to filter.
- The token secret is already configured (`config :jido_ai, :react_token_secret` in config.exs + runtime.exs), so tokens survive node restarts.
- GracefulShutdown needs NO changes: tokens are persisted continuously at every LLM/tool boundary, so the last checkpoint is already in Postgres whenever the node dies, gracefully or not. Drain-time work would only shave off the final in-flight step, which resume re-executes safely (LLM calls have no side effects).

---

### Task 1: TurnCheckpoint resource

**Files:**
- Create: `lib/magus/agents/turn_checkpoint.ex`
- Modify: `lib/magus/agents/agents.ex` (resources block + code interfaces, near the AgentRun defines around line 152)
- Create: migration via `mix ash.codegen add_agent_turn_checkpoints`
- Test: `test/magus/agents/turn_checkpoint_test.exs`

**Interfaces:**
- Produces: `Magus.Agents.upsert_turn_checkpoint(%{conversation_id, request_id, token}, authorize?: false)`, `Magus.Agents.get_turn_checkpoint(conversation_id, authorize?: false)` returning `{:ok, %TurnCheckpoint{} | nil}`, `Magus.Agents.destroy_turn_checkpoint(record, authorize?: false)`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Magus.Agents.TurnCheckpointTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    %{conversation: conversation}
  end

  test "upsert creates and then replaces the row for a conversation", %{conversation: conv} do
    {:ok, first} =
      Magus.Agents.upsert_turn_checkpoint(
        %{conversation_id: conv.id, request_id: "req-1", token: "rt1.aaa.bbb"},
        authorize?: false
      )

    {:ok, second} =
      Magus.Agents.upsert_turn_checkpoint(
        %{conversation_id: conv.id, request_id: "req-1", token: "rt1.ccc.ddd"},
        authorize?: false
      )

    assert second.id == first.id
    {:ok, fetched} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
    assert fetched.token == "rt1.ccc.ddd"
    assert fetched.request_id == "req-1"
  end

  test "get_turn_checkpoint returns nil when absent", %{conversation: conv} do
    assert {:ok, nil} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
  end

  test "destroy removes the row", %{conversation: conv} do
    {:ok, row} =
      Magus.Agents.upsert_turn_checkpoint(
        %{conversation_id: conv.id, request_id: "req-1", token: "rt1.aaa.bbb"},
        authorize?: false
      )

    :ok = Magus.Agents.destroy_turn_checkpoint(row, authorize?: false)
    assert {:ok, nil} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/turn_checkpoint_test.exs`
Expected: FAIL with `Magus.Agents.upsert_turn_checkpoint/2 is undefined`

- [ ] **Step 3: Create the resource**

```elixir
defmodule Magus.Agents.TurnCheckpoint do
  @moduledoc """
  Latest ReAct checkpoint token for an in-flight turn, one row per
  conversation. Written by `Magus.Agents.Plugins.CheckpointPlugin` on every
  non-terminal checkpoint and cleared when the turn completes or fails.
  `Magus.Agents.Recovery` redeems it on thaw so an interrupted turn resumes
  instead of restarting.

  System-only resource: no policies block, every caller uses
  `authorize?: false` (same convention as the other agent-internal writes).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "agent_turn_checkpoints"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
    end
  end

  actions do
    # The bare :update exists only so tests can force-change timestamps.
    defaults [:read, :destroy, update: []]

    create :upsert do
      upsert? true
      upsert_identity :unique_conversation
      accept [:conversation_id, :request_id, :token]
      upsert_fields [:request_id, :token, :updated_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :request_id, :string do
      allow_nil? false
      public? true
    end

    attribute :token, :string do
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_conversation, [:conversation_id]
  end
end
```

- [ ] **Step 4: Register in the domain**

In `lib/magus/agents/agents.ex`, add to the `resources do` block:

```elixir
    resource Magus.Agents.TurnCheckpoint do
      define :upsert_turn_checkpoint, action: :upsert
      define :get_turn_checkpoint, action: :read, get_by: [:conversation_id]
      define :destroy_turn_checkpoint, action: :destroy
    end
```

Note: check how the sibling resources are registered in this file (some use a bare `resource Mod` plus defines inside an existing `resource` block); match the file's existing style exactly.

- [ ] **Step 5: Generate and run the migration**

```bash
mix ash.codegen add_agent_turn_checkpoints
MIX_ENV=test mix ash.migrate
mix ash.migrate
```

Inspect the generated migration: the `conversation_id` reference must have `on_delete: :delete` (deleting a conversation must not orphan checkpoint rows).

- [ ] **Step 6: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/turn_checkpoint_test.exs`
Expected: 3 tests, 0 failures. Note: `get_by` code interfaces raise on missing by default in some Ash versions; if `get_turn_checkpoint` returns `{:error, %Ash.Error.Query.NotFound{}}` instead of `{:ok, nil}`, add `not_found_error?: false` to the define and re-run.

- [ ] **Step 7: Commit**

```bash
mix format lib/magus/agents/turn_checkpoint.ex lib/magus/agents/agents.ex test/magus/agents/turn_checkpoint_test.exs
git add lib/magus/agents/turn_checkpoint.ex test/magus/agents/turn_checkpoint_test.exs priv/repo/migrations priv/resource_snapshots
git commit -m "feat(agents): TurnCheckpoint resource for turn resume" -- lib/magus/agents/turn_checkpoint.ex lib/magus/agents/agents.ex test/magus/agents/turn_checkpoint_test.exs priv/repo/migrations priv/resource_snapshots
```

---

### Task 2: Strategy emits ai.react.checkpoint

**Files:**
- Modify: `lib/magus/agents/strategies/react_strategy.ex` (the `:checkpoint` branch of `apply_runtime_event/2`, and `signal_routes/1`)
- Test: `test/magus/agents/strategies/react_strategy_test.exs` (new describe; reuse this file's `init_agent/1` and `worker_event_instruction/2` helpers)

**Interfaces:**
- Produces: CoreSignal `"ai.react.checkpoint"` with data `%{request_id: String.t(), token: String.t(), reason: :after_llm | :after_tools}`, emitted only for non-terminal checkpoint reasons. Task 3's plugin consumes it.

- [ ] **Step 1: Write the failing test**

Add to `react_strategy_test.exs`:

```elixir
  describe "checkpoint signal emission" do
    test "non-terminal checkpoints emit ai.react.checkpoint" do
      {agent, ctx} = init_agent(tools: [TestTool])

      event = %{
        kind: :checkpoint,
        request_id: "req-chk-1",
        data: %{token: "rt1.payload.sig", reason: :after_llm}
      }

      {_agent, directives} =
        ReactStrategy.cmd(agent, [worker_event_instruction("req-chk-1", event)], ctx)

      assert Enum.any?(directives, fn directive ->
               match?(
                 %{signal: %{type: "ai.react.checkpoint", data: %{token: "rt1.payload.sig"}}},
                 directive
               )
             end)
    end

    test "terminal checkpoints do not emit the signal" do
      {agent, ctx} = init_agent(tools: [TestTool])

      event = %{
        kind: :checkpoint,
        request_id: "req-chk-2",
        data: %{token: "rt1.payload.sig", reason: :terminal}
      }

      {_agent, directives} =
        ReactStrategy.cmd(agent, [worker_event_instruction("req-chk-2", event)], ctx)

      refute Enum.any?(directives, fn directive ->
               match?(%{signal: %{type: "ai.react.checkpoint"}}, directive)
             end)
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/strategies/react_strategy_test.exs`
Expected: the first new test FAILS (no such directive emitted); the second passes trivially.

- [ ] **Step 3: Implement**

In `apply_runtime_event/2`, replace the `:checkpoint` branch body so it also emits the signal (the existing token bookkeeping stays):

```elixir
      :checkpoint ->
        token = event_field(data, :token)
        checkpoint_reason = event_field(data, :reason)

        updated =
          base_state
          |> Map.put(:checkpoint_token, token)
          |> then(fn state_after_checkpoint ->
            if state[:status] in [:completed, :error] and is_nil(state[:active_request_id]) do
              Map.put(state_after_checkpoint, :active_request_id, nil)
            else
              state_after_checkpoint
            end
          end)

        signals =
          if checkpoint_reason in [:after_llm, :after_tools] and is_binary(token) and
               is_binary(request_id) do
            [
              CoreSignal.new!(
                "ai.react.checkpoint",
                %{request_id: request_id, token: token, reason: checkpoint_reason},
                source: @source
              )
            ]
          else
            []
          end

        {updated, signals}
```

In `signal_routes/1`, add alongside the other emitted-signal noop routes:

```elixir
      {"ai.react.checkpoint", Jido.Actions.Control.Noop},
```

- [ ] **Step 4: Run to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/strategies/react_strategy_test.exs`
Expected: all pass. If the directive struct shape differs from `%{signal: ...}`, inspect one directive with `IO.inspect(directives)` once, fix the match pattern in the test, and remove the inspect.

- [ ] **Step 5: Commit**

```bash
mix format lib/magus/agents/strategies/react_strategy.ex test/magus/agents/strategies/react_strategy_test.exs
git commit -m "feat(agents): emit ai.react.checkpoint for non-terminal checkpoints" -- lib/magus/agents/strategies/react_strategy.ex test/magus/agents/strategies/react_strategy_test.exs
```

---

### Task 3: CheckpointPlugin persists and clears tokens

**Files:**
- Create: `lib/magus/agents/plugins/checkpoint_plugin.ex`
- Modify: `lib/magus/agents/conversation_agent.ex` (plugins list: insert after `Magus.Agents.Plugins.PersistencePlugin`)
- Test: `test/magus/agents/plugins/checkpoint_plugin_test.exs`

**Interfaces:**
- Consumes: `"ai.react.checkpoint"` (Task 2), `Magus.Agents.upsert_turn_checkpoint/2`, `get_turn_checkpoint/2`, `destroy_turn_checkpoint/2` (Task 1), `Magus.Agents.Plugins.Support.Helpers.get_conversation_id/1`.
- Produces: TurnCheckpoint rows kept current during a turn, deleted on `"ai.request.completed"` / `"ai.request.failed"`.

- [ ] **Step 1: Write the failing test**

Mirror the helper style of `test/magus/agents/plugins/agent_run_completion_plugin_test.exs` (build_agent map + `Jido.Signal.new!`):

```elixir
defmodule Magus.Agents.Plugins.CheckpointPluginTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.CheckpointPlugin

  defp build_agent(conversation_id) do
    %{
      id: "conv:#{conversation_id}",
      state: %{conversation_id: conversation_id, user_id: "test-user-id"}
    }
  end

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    %{conversation: conversation}
  end

  test "ai.react.checkpoint upserts the row", %{conversation: conv} do
    agent = build_agent(to_string(conv.id))

    signal =
      Jido.Signal.new!("ai.react.checkpoint", %{
        request_id: "req-1",
        token: "rt1.first.sig",
        reason: :after_llm
      })

    assert {:ok, :continue} = CheckpointPlugin.handle_signal(signal, %{agent: agent})

    {:ok, row} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
    assert row.token == "rt1.first.sig"
    assert row.request_id == "req-1"
  end

  test "completion clears the row", %{conversation: conv} do
    {:ok, _} =
      Magus.Agents.upsert_turn_checkpoint(
        %{conversation_id: conv.id, request_id: "req-1", token: "rt1.a.b"},
        authorize?: false
      )

    agent = build_agent(to_string(conv.id))
    signal = Jido.Signal.new!("ai.request.completed", %{request_id: "req-1"})

    assert {:ok, :continue} = CheckpointPlugin.handle_signal(signal, %{agent: agent})
    assert {:ok, nil} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
  end

  test "failure clears the row", %{conversation: conv} do
    {:ok, _} =
      Magus.Agents.upsert_turn_checkpoint(
        %{conversation_id: conv.id, request_id: "req-1", token: "rt1.a.b"},
        authorize?: false
      )

    agent = build_agent(to_string(conv.id))
    signal = Jido.Signal.new!("ai.request.failed", %{request_id: "req-1"})

    assert {:ok, :continue} = CheckpointPlugin.handle_signal(signal, %{agent: agent})
    assert {:ok, nil} = Magus.Agents.get_turn_checkpoint(conv.id, authorize?: false)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/plugins/checkpoint_plugin_test.exs`
Expected: FAIL, `CheckpointPlugin` undefined.

- [ ] **Step 3: Implement the plugin**

```elixir
defmodule Magus.Agents.Plugins.CheckpointPlugin do
  @moduledoc """
  Persists the latest ReAct checkpoint token per conversation so an
  interrupted turn (deploy, crash) can be resumed by `Magus.Agents.Recovery`
  instead of restarted from scratch. Rows are upserted on every non-terminal
  checkpoint and deleted when the turn reaches a terminal signal. All writes
  are best effort: checkpointing must never break a turn.
  """

  use Jido.Plugin,
    name: "turn_checkpoint",
    state_key: :turn_checkpoint,
    actions: [],
    description: "Persists ReAct checkpoint tokens for crash/deploy resume",
    category: "magus",
    tags: ["resilience", "checkpoint"],
    signal_patterns: [
      "ai.react.checkpoint",
      "ai.request.completed",
      "ai.request.failed"
    ]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers

  @impl Jido.Plugin
  def mount(_agent, config), do: {:ok, %{config: config}}

  @impl Jido.Plugin
  def handle_signal(%{type: "ai.react.checkpoint"} = signal, context) do
    conversation_id = Helpers.get_conversation_id(context[:agent])
    data = signal.data || %{}
    token = data[:token] || data["token"]
    request_id = data[:request_id] || data["request_id"]

    if is_binary(conversation_id) and is_binary(token) and is_binary(request_id) do
      case Magus.Agents.upsert_turn_checkpoint(
             %{conversation_id: conversation_id, request_id: request_id, token: token},
             authorize?: false
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("CheckpointPlugin: upsert failed: #{inspect(reason)}")
      end
    end

    {:ok, :continue}
  end

  def handle_signal(%{type: type}, context)
      when type in ["ai.request.completed", "ai.request.failed"] do
    conversation_id = Helpers.get_conversation_id(context[:agent])

    with true <- is_binary(conversation_id),
         {:ok, %{} = row} <- Magus.Agents.get_turn_checkpoint(conversation_id, authorize?: false) do
      Magus.Agents.destroy_turn_checkpoint(row, authorize?: false)
    end

    {:ok, :continue}
  rescue
    e ->
      Logger.warning("CheckpointPlugin: clear failed: #{Exception.message(e)}")
      {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}
end
```

- [ ] **Step 4: Register in ConversationAgent**

In `lib/magus/agents/conversation_agent.ex`, plugins list, directly after `Magus.Agents.Plugins.PersistencePlugin,`:

```elixir
      Magus.Agents.Plugins.CheckpointPlugin,
```

- [ ] **Step 5: Run tests, then the plugin + conversation agent suites**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/plugins/checkpoint_plugin_test.exs test/magus/agents/conversation_agent_test.exs`
Expected: all pass (the conversation_agent_test has a plugin-list assertion describe; if it asserts an exact list, add the new plugin there).

- [ ] **Step 6: Commit**

```bash
mix format lib/magus/agents/plugins/checkpoint_plugin.ex lib/magus/agents/conversation_agent.ex test/magus/agents/plugins/checkpoint_plugin_test.exs
git commit -m "feat(agents): CheckpointPlugin persists turn checkpoint tokens" -- lib/magus/agents/plugins/checkpoint_plugin.ex lib/magus/agents/conversation_agent.ex test/magus/agents/plugins/checkpoint_plugin_test.exs test/magus/agents/conversation_agent_test.exs
```

---

### Task 4: Worker resumes from a token (with dangling-tool-call healing)

**Files:**
- Modify: `lib/magus/agents/strategies/react/worker/strategy.ex` (`@start` schema, `start_run/2`, new helpers)
- Modify: `lib/magus/agents/strategies/react_strategy.ex` (parent `@start` action schema gains `checkpoint_token`; `process_start/2` forwards it into `worker_start_payload`, omitting the key when nil)
- Test: `test/magus/agents/strategies/react/worker_resume_test.exs`

**Interfaces:**
- Consumes: `Jido.AI.Reasoning.ReAct.Token.issue/2` and `.decode_state/2`; `Jido.AI.Thread` entry structure (`%Thread.Entry{role: :assistant, tool_calls: [...]}`, `%Thread.Entry{role: :tool, tool_call_id: ...}`).
- Produces: `Worker.Strategy.resume_state_from_token(token :: String.t() | nil, request_id :: String.t(), config :: Config.t()) :: ReActState.t() | nil` (public, `@doc false`) and `Worker.Strategy.heal_dangling_tool_calls(state :: ReActState.t()) :: ReActState.t()` (public, `@doc false`). The parent's `worker_start_payload` may carry `checkpoint_token: String.t()` (key omitted when absent).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Magus.Agents.Strategies.ReactStrategy.WorkerResumeTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Reasoning.ReAct.Config
  alias Jido.AI.Reasoning.ReAct.State, as: ReActState
  alias Jido.AI.Reasoning.ReAct.Token
  alias Jido.AI.Thread
  alias Magus.Agents.Strategies.ReactStrategy.Worker.Strategy, as: Worker

  defp config do
    Config.new(%{model: "mock:test-model", tools: [], max_iterations: 10, streaming: true})
  end

  defp mid_turn_state do
    state = ReActState.new("do the task", "system prompt", request_id: "req-r1", run_id: "run-r1")
    thread = Thread.append_assistant(state.thread, "working on it", nil, [])
    %{state | thread: thread, iteration: 2}
  end

  test "round-trips a token back into runtime state" do
    cfg = config()
    token = Token.issue(mid_turn_state(), cfg)

    assert %ReActState{request_id: "req-r1", iteration: 2} =
             Worker.resume_state_from_token(token, "req-r1", cfg)
  end

  test "returns nil for garbage tokens, nil tokens, and request_id mismatches" do
    cfg = config()
    token = Token.issue(mid_turn_state(), cfg)

    assert Worker.resume_state_from_token(nil, "req-r1", cfg) == nil
    assert Worker.resume_state_from_token("rt1.garbage.sig", "req-r1", cfg) == nil
    assert Worker.resume_state_from_token(token, "some-other-request", cfg) == nil
  end

  test "returns nil on config fingerprint mismatch" do
    token = Token.issue(mid_turn_state(), config())

    other_cfg =
      Config.new(%{model: "mock:other-model", tools: [], max_iterations: 10, streaming: true})

    assert Worker.resume_state_from_token(token, "req-r1", other_cfg) == nil
  end

  test "heals a trailing assistant message with dangling tool calls" do
    state = ReActState.new("q", "sys", request_id: "req-r2", run_id: "run-r2")

    tool_calls = [ReqLLM.ToolCall.new("call_1", "some_tool", "{}")]
    thread = Thread.append_assistant(state.thread, "calling tool", tool_calls, [])
    state = %{state | thread: thread}

    healed = Worker.heal_dangling_tool_calls(state)

    entries = healed.thread.entries
    assert %{role: :tool, tool_call_id: "call_1"} = List.last(entries)
    assert (List.last(entries)).content =~ "interrupted"
  end

  test "leaves a thread with completed tool results untouched" do
    state = ReActState.new("q", "sys", request_id: "req-r3", run_id: "run-r3")

    tool_calls = [ReqLLM.ToolCall.new("call_1", "some_tool", "{}")]

    thread =
      state.thread
      |> Thread.append_assistant("calling tool", tool_calls, [])
      |> Thread.append_tool_result("call_1", "some_tool", "result body")

    state = %{state | thread: thread}
    assert Worker.heal_dangling_tool_calls(state) == state
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/strategies/react/worker_resume_test.exs`
Expected: FAIL, `resume_state_from_token/3` undefined. If `Thread.entries` ordering or entry field names differ from the assertions, inspect one thread (`IO.inspect(thread)`) and adjust the test to the real structure once; the entry struct is `Jido.AI.Thread.Entry`.

- [ ] **Step 3: Implement the helpers in the worker strategy**

```elixir
  @doc false
  # Rebuilds runtime state from a persisted checkpoint token. Best effort:
  # any failure (bad signature, expiry, config fingerprint mismatch, foreign
  # request) returns nil and the caller starts fresh from message history.
  def resume_state_from_token(token, request_id, %Config{} = config)
      when is_binary(token) and is_binary(request_id) do
    case Jido.AI.Reasoning.ReAct.Token.decode_state(token, config) do
      {:ok, %ReActState{request_id: ^request_id} = state, _payload} ->
        Logger.info("ReactWorker: resuming request #{request_id} from checkpoint")
        heal_dangling_tool_calls(state)

      {:ok, %ReActState{request_id: other}, _payload} ->
        Logger.warning(
          "ReactWorker: checkpoint belongs to #{inspect(other)}, not #{request_id}; starting fresh"
        )

        nil

      {:error, reason} ->
        Logger.warning("ReactWorker: checkpoint resume failed (#{inspect(reason)}); starting fresh")
        nil
    end
  end

  def resume_state_from_token(_token, _request_id, _config), do: nil

  @doc false
  # A token checkpointed :after_llm can carry a trailing assistant entry with
  # tool_calls whose tool round never ran (the interruption hit mid-round).
  # Resuming such a thread would send dangling tool_calls to the provider,
  # which most reject. Append a synthetic tool result per unanswered call so
  # the model re-plans and re-issues any tool it still needs.
  def heal_dangling_tool_calls(%ReActState{thread: %Thread{entries: entries} = thread} = state) do
    answered_ids =
      entries
      |> Enum.filter(&(&1.role == :tool))
      |> MapSet.new(& &1.tool_call_id)

    dangling =
      case List.last(entries) do
        %{role: :assistant, tool_calls: calls} when is_list(calls) and calls != [] ->
          Enum.reject(calls, fn call -> MapSet.member?(answered_ids, call.id) end)

        _ ->
          []
      end

    healed_thread =
      Enum.reduce(dangling, thread, fn call, acc ->
        Thread.append_tool_result(
          acc,
          call.id,
          tool_call_name(call),
          "(tool execution was interrupted by a restart; call the tool again if the result is still needed)"
        )
      end)

    %{state | thread: healed_thread}
  end

  def heal_dangling_tool_calls(state), do: state

  defp tool_call_name(%{name: name}) when is_binary(name), do: name
  defp tool_call_name(%{function: %{name: name}}) when is_binary(name), do: name
  defp tool_call_name(_), do: "unknown_tool"
```

Note the `ReqLLM.ToolCall` shape: check whether `.name` is top-level or nested under `.function` (the checkpoint blob showed `function: %{name: ...}`); `tool_call_name/1` covers both.

- [ ] **Step 4: Wire into start_run and the payload schemas**

Worker `@start` Zoi schema, after `parent_pid`:

```elixir
          checkpoint_token: Zoi.string() |> Zoi.optional()
```

In `start_run/2`, replace the `runtime_state =` binding:

```elixir
      runtime_state =
        resume_state_from_token(Map.get(params, :checkpoint_token), request_id, config) ||
          runtime_state_from_messages(query, request_id, run_id, config, thread_messages)
```

Parent `react_strategy.ex`: add to the `@start` action Zoi schema:

```elixir
          checkpoint_token: Zoi.string() |> Zoi.optional(),
```

and in `process_start/2`, extend the `worker_start_payload` pipeline (the same `then` block that conditionally puts `initial_messages`) with:

```elixir
        |> then(fn payload ->
          case Map.get(params, :checkpoint_token) do
            token when is_binary(token) and token != "" ->
              Map.put(payload, :checkpoint_token, token)

            _ ->
              payload
          end
        end)
```

- [ ] **Step 5: Run tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/strategies/react/worker_resume_test.exs test/magus/agents/strategies`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
mix format lib/magus/agents/strategies/react/worker/strategy.ex lib/magus/agents/strategies/react_strategy.ex test/magus/agents/strategies/react/worker_resume_test.exs
git commit -m "feat(agents): worker resumes runtime state from checkpoint tokens" -- lib/magus/agents/strategies/react/worker/strategy.ex lib/magus/agents/strategies/react_strategy.ex test/magus/agents/strategies/react/worker_resume_test.exs
```

---

### Task 5: Dispatch carries the token (Dispatcher + InboundPlugin)

**Files:**
- Modify: `lib/magus/agents/dispatcher.ex` (`build_signal_data/3`, new `dispatch_resume/2`)
- Modify: `lib/magus/agents/plugins/inbound_plugin.ex` (forward `checkpoint_token` from `message.user` data into the `ai.react.query` params)
- Test: `test/magus/agents/dispatcher_test.exs` (extend), `test/magus/agents/plugins/inbound_plugin_test.exs` (extend)

**Interfaces:**
- Consumes: the original interrupted `%Magus.Chat.Message{}` and a token string (from Task 6's Recovery).
- Produces: `Magus.Agents.Dispatcher.dispatch_resume(message, token)` which dispatches the ORIGINAL message with `checkpoint_token` in the signal data; InboundPlugin passes `checkpoint_token` through to the `ai.react.query` params so Task 4's parent schema receives it.

- [ ] **Step 1: Write the failing tests**

In `dispatcher_test.exs` (it already tests `build_signal_data/3`; mirror its fixture style):

```elixir
  test "build_signal_data forwards a checkpoint_token from message metadata" do
    message = %{
      id: Ecto.UUID.generate(),
      text: "resume me",
      attachments: [],
      mode: :chat,
      created_by_id: Ecto.UUID.generate(),
      selected_model_id: nil,
      metadata: %{"checkpoint_token" => "rt1.abc.def"}
    }

    conversation = %{chat_mode: :chat, workspace_id: nil}
    routed = %{routing_reason: nil, model_keys: %{chat: "test-model"}}

    data = Magus.Agents.Dispatcher.build_signal_data(message, conversation, routed)
    assert data[:checkpoint_token] == "rt1.abc.def"
  end
```

Note: match the exact fixture shapes already used in `dispatcher_test.exs` for `message`/`conversation`/`routed`; if the existing tests build them differently, copy that style rather than the sketch above.

In `inbound_plugin_test.exs`, add a focused test that does NOT assert on model resolution (the model assertions are broken by shared-DB leakage):

```elixir
    test "forwards checkpoint_token from message.user to ai.react.query" do
      user = generate(user())
      ensure_active_subscription(user)
      conversation = generate(conversation(actor: user))

      agent =
        build_agent(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "resume",
          mode: :chat,
          checkpoint_token: "rt1.abc.def"
        })

      assert {:ok, {:continue, react_signal}} =
               InboundPlugin.handle_signal(signal, build_context(agent))

      assert react_signal.data[:checkpoint_token] == "rt1.abc.def"
    end
```

- [ ] **Step 2: Run to verify both fail**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/dispatcher_test.exs test/magus/agents/plugins/inbound_plugin_test.exs`
Expected: the two new tests FAIL (missing key); the two pre-existing model-resolution failures in inbound_plugin_test are known and not yours.

- [ ] **Step 3: Implement**

`dispatcher.ex` — in `build_signal_data/3`, the metadata map is already read (`metadata = message.metadata || %{}`); add to the returned map:

```elixir
      checkpoint_token: metadata["checkpoint_token"] || metadata[:checkpoint_token],
```

and add the public resume entry point:

```elixir
  @doc """
  Re-dispatches an interrupted message WITH its checkpoint token so the
  strategy resumes the turn from the persisted runtime state instead of
  restarting it. Falls back to plain re-dispatch semantics if the token is
  rejected downstream (the worker degrades to a fresh start on its own).
  """
  @spec dispatch_resume(map(), String.t()) :: {:ok, dispatch_result()} | {:error, term()}
  def dispatch_resume(message, checkpoint_token) when is_binary(checkpoint_token) do
    metadata = Map.put(message.metadata || %{}, "checkpoint_token", checkpoint_token)
    dispatch_message(%{message | metadata: metadata}, message.conversation_id, nil)
  end
```

`inbound_plugin.ex` — find where the `ai.react.query` signal data map is built from the incoming `message.user` data (the map containing `query:`, `request_id:`, `initial_messages:`); add:

```elixir
        checkpoint_token: data[:checkpoint_token] || data["checkpoint_token"],
```

CAUTION (global constraint): the parent strategy's Zoi schema rejects explicit nil for optional typed fields IF the value is validated as a string. Verify how InboundPlugin handles other optional keys (e.g. `model`): if it omits nil keys via a helper, use the same helper for `checkpoint_token`; a bare `checkpoint_token: nil` in the params map must be confirmed harmless (Zoi optional + nil value) by the test run before moving on. If the run shows a Zoi error, omit the key when nil instead.

- [ ] **Step 4: Run to verify both pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/dispatcher_test.exs test/magus/agents/plugins/inbound_plugin_test.exs`
Expected: the two new tests pass; only the two known pre-existing failures remain.

- [ ] **Step 5: Commit**

```bash
mix format lib/magus/agents/dispatcher.ex lib/magus/agents/plugins/inbound_plugin.ex test/magus/agents/dispatcher_test.exs test/magus/agents/plugins/inbound_plugin_test.exs
git commit -m "feat(agents): thread checkpoint_token through dispatch and inbound" -- lib/magus/agents/dispatcher.ex lib/magus/agents/plugins/inbound_plugin.ex test/magus/agents/dispatcher_test.exs test/magus/agents/plugins/inbound_plugin_test.exs
```

---

### Task 6: Recovery resumes instead of re-dispatching

**Files:**
- Modify: `lib/magus/agents/recovery.ex` (`maybe_redispatch/2`, new `fresh_checkpoint_for/2`)
- Test: `test/magus/agents/recovery_test.exs` (extend)

**Interfaces:**
- Consumes: `Magus.Agents.get_turn_checkpoint/2` (Task 1), `Magus.Agents.Dispatcher.dispatch_resume/2` (Task 5).
- Produces: `Recovery.recover_interrupted_turn/2` returns `{:resumed, message_id}` when a fresh matching checkpoint exists; `Recovery.fresh_checkpoint_for(conversation_id, message)` public (`@doc false`) returning `%TurnCheckpoint{} | nil`.

- [ ] **Step 1: Write the failing tests**

Add to `recovery_test.exs` (reuse its setup: `%{user: user, conversation: conversation}`):

```elixir
  describe "fresh_checkpoint_for/2" do
    test "returns the checkpoint when it matches the interrupted message and is fresh", %{
      user: user,
      conversation: conversation
    } do
      message = generate(message(actor: user, conversation_id: conversation.id, text: "long task"))

      {:ok, _} =
        Magus.Agents.upsert_turn_checkpoint(
          %{
            conversation_id: conversation.id,
            request_id: to_string(message.id),
            token: "rt1.abc.def"
          },
          authorize?: false
        )

      checkpoint = Magus.Agents.Recovery.fresh_checkpoint_for(to_string(conversation.id), message)
      assert checkpoint.token == "rt1.abc.def"
    end

    test "returns nil when the checkpoint belongs to a different message", %{
      user: user,
      conversation: conversation
    } do
      message = generate(message(actor: user, conversation_id: conversation.id, text: "task"))

      {:ok, _} =
        Magus.Agents.upsert_turn_checkpoint(
          %{
            conversation_id: conversation.id,
            request_id: Ecto.UUID.generate(),
            token: "rt1.abc.def"
          },
          authorize?: false
        )

      assert Magus.Agents.Recovery.fresh_checkpoint_for(to_string(conversation.id), message) == nil
    end

    test "returns nil when no checkpoint exists", %{user: user, conversation: conversation} do
      message = generate(message(actor: user, conversation_id: conversation.id, text: "task"))
      assert Magus.Agents.Recovery.fresh_checkpoint_for(to_string(conversation.id), message) == nil
    end

    test "returns nil when the checkpoint is older than the freshness window", %{
      user: user,
      conversation: conversation
    } do
      message = generate(message(actor: user, conversation_id: conversation.id, text: "task"))

      {:ok, row} =
        Magus.Agents.upsert_turn_checkpoint(
          %{
            conversation_id: conversation.id,
            request_id: to_string(message.id),
            token: "rt1.abc.def"
          },
          authorize?: false
        )

      stale = DateTime.add(DateTime.utc_now(), -25, :hour)

      row
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:updated_at, stale)
      |> Ash.update!(authorize?: false)

      assert Magus.Agents.Recovery.fresh_checkpoint_for(to_string(conversation.id), message) == nil
    end
  end
```

Note: the stale test force-changes `updated_at`; if the `TurnCheckpoint` resource has no generic `:update` action, add `update :update do accept [] end` to it (or use `defaults [:read, :destroy, :update]` in Task 1's actions block from the start).

- [ ] **Step 2: Run to verify RED**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/recovery_test.exs`
Expected: new tests FAIL, `fresh_checkpoint_for/2` undefined.

- [ ] **Step 3: Implement**

In `recovery.ex`:

```elixir
  @checkpoint_freshness_hours 24

  @doc false
  # A checkpoint is usable when it belongs to the interrupted message
  # (request_id == message id) and is fresh enough that resuming beats
  # restarting. Anything else resolves to nil and the caller re-dispatches.
  def fresh_checkpoint_for(conversation_id, %{id: message_id}) do
    case Magus.Agents.get_turn_checkpoint(conversation_id, authorize?: false) do
      {:ok, %{} = checkpoint} ->
        fresh? =
          DateTime.diff(DateTime.utc_now(), checkpoint.updated_at, :hour) <
            @checkpoint_freshness_hours

        if checkpoint.request_id == to_string(message_id) and fresh? do
          checkpoint
        else
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def fresh_checkpoint_for(_conversation_id, _message), do: nil
```

And in `maybe_redispatch/2`, replace the else-branch of the `newer_user_message_exists?` check (the branch that currently logs and calls `Dispatcher.dispatch_user_message(message)`):

```elixir
        else
          case fresh_checkpoint_for(conversation_id, message) do
            %{token: token} ->
              Logger.info(
                "Recovery: resuming message #{message.id} from checkpoint for #{conversation_id}"
              )

              Magus.Agents.Dispatcher.dispatch_resume(message, token)

              trace_recovery(
                conversation_id,
                "Recovery resumed the interrupted turn from its checkpoint",
                %{conversation_id: conversation_id, message_id: message.id}
              )

              {:resumed, message.id}

            nil ->
              Logger.info(
                "Recovery: re-dispatching message #{message.id} for conversation #{conversation_id}"
              )

              Magus.Agents.Dispatcher.dispatch_user_message(message)

              trace_recovery(
                conversation_id,
                "Recovery re-dispatched the interrupted turn",
                %{conversation_id: conversation_id, message_id: message.id}
              )

              {:dispatched, message.id}
          end
        end
```

Also update the `@spec` of `recover_interrupted_turn/2` to include `{:resumed, term()}`.

- [ ] **Step 4: Run recovery tests**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/recovery_test.exs`
Expected: all pass (existing tests untouched: with no checkpoint row they take the `nil` branch and keep returning `{:dispatched, _}`).

- [ ] **Step 5: Commit**

```bash
mix format lib/magus/agents/recovery.ex test/magus/agents/recovery_test.exs
git commit -m "feat(agents): Recovery resumes turns from checkpoints when available" -- lib/magus/agents/recovery.ex test/magus/agents/recovery_test.exs
```

---

### Task 7: Full-suite verification and documentation

**Files:**
- Modify: `CLAUDE.md` (Jido Agent Architecture section, the hibernation/recovery paragraph)
- No new code.

- [ ] **Step 1: Full agents suite**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents`
Expected: 0 failures beyond the 2 known pre-existing InboundPlugin model-resolution failures.

- [ ] **Step 2: Warnings-as-errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Update CLAUDE.md**

In the paragraph that reads "Mid-turn hibernation is detected by `Magus.Agents.Recovery` (via `__recovery__` key) and the turn is retried", change the tail to:

```markdown
Mid-turn hibernation is detected by `Magus.Agents.Recovery` (via `__recovery__` key); the turn is RESUMED from its persisted checkpoint token (`TurnCheckpoint` row, written by `CheckpointPlugin` each LLM/tool boundary) when one exists, and re-dispatched from scratch otherwise; streaming messages stuck in `:streaming` get cleaned up.
```

- [ ] **Step 4: Manual smoke (dev, optional but recommended)**

With the dev server running and a conversation with a multi-tool prompt in flight, run in the dev node (via Tidewave `project_eval`, not a second mix instance):

```elixir
Jido.Agent.InstanceManager.stop(:conversations, "conv:<conversation-uuid>")
```

mid-turn, then send nothing and reopen the conversation (or wait for the next message) and confirm in logs: `Recovery: resuming message ... from checkpoint`.

- [ ] **Step 5: Commit**

```bash
git commit -m "docs: describe checkpoint-resume in agent architecture" -- CLAUDE.md
```

---

## Out of Scope (explicitly)

- Tool idempotency keys (bounded one-round duplication is accepted).
- Filtering the interrupted attempt's tool-event messages out of `initial_messages` on resume (accepted duplication; candidate follow-up).
- Live E2E resume test (`bin/test-e2e-live`): valuable but nondeterministic with a real LLM; add later as `@tag :e2e_live` if wanted.
- Resuming across code deploys that change a conversation's toolset (config fingerprint mismatch falls back to re-dispatch by design).
