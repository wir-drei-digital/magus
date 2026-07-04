# Memory Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the structural gaps in the current memory pipeline (extraction signal loss, no retries, circular decay, information-free signals, unbounded prompt block) and prove the improvement with LongMemEval-S runs before and after.

**Architecture:** No new subsystems. Turn extraction moves from "latest pair, fire-and-forget" to "all turns since a watermark, retryable inside the Oban job". Retrieval stops refreshing the decay clock for ambiently injected memories, association weights decay at read time, and the injected memory block gets a hard budget. An eval baseline is recorded first and re-run last with identical parameters.

**Tech Stack:** Ash 3.x, AshOban, Jido actions, pgvector, Mox (LLMMock), Magus.Eval (LongMemEval-S).

## Global Constraints

- NEVER run `mix ash.reset` (wipes all data). Schema changes go through `mix ash.codegen <name>` + `mix ash.migrate`.
- Before any push: `MIX_ENV=test mix compile --warnings-as-errors` must pass (CI compiles with warnings-as-errors).
- Do not run `mix compile` via shell while the Tidewave dev server is running; tests are fine (`mix test` uses its own build).
- Eval runs need `.env` loaded (`set -a && source .env && set +a`) and cost real OpenRouter money. Always use `--limit 60` so runs are comparable.
- Nullable Jido schema fields MUST use `{:or, [<type>, nil]}` (bare type + `default: nil` silently breaks the tool).
- No em dashes in any prose or docs written during this plan.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Record the eval baseline

Nothing may change before this task completes. The baseline is the comparison anchor for every later task.

**Files:**
- Create: `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`

**Interfaces:**
- Produces: a baselines doc that Task 9 appends to. Scoreboard rows land in `eval/results/longmemeval.jsonl` automatically (append-only, keyed by git sha).

- [ ] **Step 1: Verify the dataset and env are available**

Run:
```bash
cd /Users/daniel/Development/magus
set -a && source .env && set +a
test -n "$OPENROUTER_API_KEY" && echo "key ok"
```
Expected: `key ok`. If the LongMemEval dataset is not cached locally, the loader downloads it on first run (see `lib/magus/eval/benchmarks/long_mem_eval/loader.ex` for the path/URL config if the run errors with a file-not-found).

- [ ] **Step 2: Run the baseline**

Run:
```bash
set -a && source .env && set +a
MIX_ENV=test mix magus.eval longmemeval --limit 60
```
Expected output ends with lines like:
```
longmemeval aggregate: 0.XXXX
scoreboard: eval/results/longmemeval.jsonl
```
This takes a while (real LLM calls through the full extraction + recall pipeline). If it fails on a single case timeout, re-run once; the scoreboard is append-only so a failed partial run does no harm.

- [ ] **Step 3: Extract per-ability numbers from the scoreboard**

Run:
```bash
tail -1 eval/results/longmemeval.jsonl | jq 'keys'
```
Expected: keys including `aggregate`, `cases`, `git_sha`, `recorded_at`. Then:
```bash
tail -1 eval/results/longmemeval.jsonl | jq '.cases | group_by(.question_type) | map({type: .[0].question_type, total: length, correct: (map(select(.["correct?"])) | length)})'
```
Expected: a JSON array with one entry per ability (e.g. `single-session-user`, `multi-session`, `knowledge-update`, `temporal-reasoning`). If the row shape differs, inspect with `jq '.cases[0]'` and adjust the key names accordingly.

- [ ] **Step 4: Write the baselines doc**

Create `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`:

```markdown
# Memory eval baselines

All runs: `MIX_ENV=test mix magus.eval longmemeval --limit 60`, Live subject.
Predictions to check after hardening: knowledge-update and multi-session
abilities should improve most (extraction window + replace mode); temporal
should improve slightly; single-session abilities should hold steady.

## Baseline (pre-hardening)

- Date: 2026-07-04
- Git SHA: <sha from scoreboard row>
- Aggregate: <value>
- Per ability:
  | ability | total | correct | accuracy |
  |---|---|---|---|
  | <fill from Step 3 output> | | | |
```

Fill in every `<...>` from the actual run output. No placeholders may remain.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-07-04-memory-eval-baselines.md
git commit -m "docs(eval): record LongMemEval-S baseline before memory hardening" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Make turn extraction retryable (Oban-native, no fire-and-forget)

Today `Magus.Chat.Conversation.Changes.ExtractTurnMemories` clears `extraction_due_at` in the changeset and spawns the LLM work via `Task.Supervisor.start_child`. Any LLM failure loses the signal forever because the Oban job already succeeded. Move the work into an `after_transaction` hook (outside the DB transaction, inside the Oban job) and propagate errors so Oban retries.

**Files:**
- Modify: `lib/magus/chat/conversation/changes/extract_turn_memories.ex` (whole file)
- Modify: `lib/magus/chat/conversation.ex:24-33` (trigger block: add `max_attempts`)
- Test: `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.Agents.Actions.ExtractTurnMemories.run/2` (unchanged in this task).
- Produces: the change now returns `{:error, reason}` from the conversation update action when extraction fails. Task 3 rewrites `load_last_turn/1` into `load_turns_since/1`; keep the function boundaries introduced here.

- [ ] **Step 1: Write the failing test**

Create `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`:

```elixir
defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemoriesChangeTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  defp seed_turn!(conv, user_text, agent_text) do
    Ash.Seed.seed!(Magus.Chat.Message, %{
      conversation_id: conv.id,
      role: :user,
      text: user_text,
      message_type: :message,
      status: :complete
    })

    Ash.Seed.seed!(Magus.Chat.Message, %{
      conversation_id: conv.id,
      role: :agent,
      text: agent_text,
      message_type: :message,
      status: :complete
    })
  end

  defp run_extract_action(conv) do
    conv
    |> Ash.Changeset.for_update(:extract_turn_memories, %{}, authorize?: false)
    |> Ash.update()
  end

  test "extraction runs inline and the action succeeds when the LLM succeeds" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    seed_turn!(
      conv,
      String.duplicate("I prefer tabs over spaces in all my projects. ", 3),
      String.duplicate("Noted, I will use tabs going forward in code I write for you. ", 3)
    )

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"extractions" => []})
    end)

    assert {:ok, updated} = run_extract_action(conv)
    assert is_nil(updated.extraction_due_at)
  end

  test "the action fails when the LLM fails, so Oban retries the job" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    seed_turn!(
      conv,
      String.duplicate("I prefer tabs over spaces in all my projects. ", 3),
      String.duplicate("Noted, I will use tabs going forward in code I write for you. ", 3)
    )

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      {:error, :llm_unavailable}
    end)

    assert {:error, _reason} = run_extract_action(conv)
  end
end
```

Note: `Ash.Seed.seed!/2` bypasses the create action, so `SignalAgent` does not fire for the seeded messages.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`
Expected: FAIL. The current change spawns a Task, so the LLM mock is either not called from the test process (Mox ownership error) or the action succeeds despite the error expectation. Either failure mode confirms the current fire-and-forget behavior.

- [ ] **Step 3: Rewrite the change to run inline via after_transaction**

Replace the body of `lib/magus/chat/conversation/changes/extract_turn_memories.ex` with:

```elixir
defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemories do
  @moduledoc """
  Ash change module that triggers turn-level memory extraction.

  Triggered by AshOban when `extraction_due_at` has passed. Clears the
  `extraction_due_at` field, then runs extraction inline in an
  `after_transaction` hook: outside the DB transaction (LLM calls must not
  hold a connection) but inside the Oban job, so an LLM failure fails the
  job and Oban retries it. The previous version spawned a fire-and-forget
  Task here, which permanently lost the turn on any LLM error.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Agents.Actions.ExtractTurnMemories, as: ExtractAction

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:extraction_due_at, nil)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, conversation} ->
        case run_extraction(conversation) do
          :ok -> {:ok, conversation}
          {:error, reason} -> {:error, reason}
        end

      _changeset, error ->
        error
    end)
  end

  defp run_extraction(conversation) do
    case load_last_turn(conversation.id) do
      {:ok, user_message, agent_response} ->
        if String.length(user_message) > 50 and String.length(agent_response) > 100 do
          allow_global = agent_allows_global_writes?(conversation)

          case ExtractAction.run(
                 %{
                   user_id: to_string(conversation.user_id),
                   conversation_id: to_string(conversation.id),
                   user_message: user_message,
                   agent_response: agent_response,
                   allow_global_memories: allow_global
                 },
                 %{}
               ) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          :ok
        end

      :skip ->
        :ok
    end
  end

  # Oban triggers provide bare conversations without preloads, so we
  # explicitly load the custom_agent association here.
  defp agent_allows_global_writes?(conversation) do
    case Ash.load(conversation, [:custom_agent], authorize?: false) do
      {:ok, %{custom_agent: %{can_write_global_memories: false}}} -> false
      _ -> true
    end
  end

  defp load_last_turn(conversation_id) do
    require Ash.Query

    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and role in [:user, :agent])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(10)
         |> Ash.read(authorize?: false) do
      {:ok, messages} ->
        agent_msg = Enum.find(messages, fn m -> m.role == :agent and (m.text || "") != "" end)
        user_msg = Enum.find(messages, fn m -> m.role == :user and (m.text || "") != "" end)

        if agent_msg && user_msg do
          {:ok, user_msg.text, agent_msg.text}
        else
          :skip
        end

      {:error, _} ->
        :skip
    end
  end
end
```

(`load_last_turn/1` is still the old single-pair logic; Task 3 replaces it. This task only fixes the execution model.)

- [ ] **Step 4: Add retry budget to the trigger**

In `lib/magus/chat/conversation.ex`, inside the `trigger :extract_turn_memories do ... end` block (lines 24-33), add one line:

```elixir
        max_attempts 5
```

- [ ] **Step 5: Run the tests**

Run: `mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs test/magus/agents/actions/extract_turn_memories_test.exs`
Expected: PASS (both new tests and the existing action tests).

- [ ] **Step 6: Commit**

```bash
git add lib/magus/chat/conversation/changes/extract_turn_memories.ex lib/magus/chat/conversation.ex test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs
git commit -m "fix(memory): run turn extraction inline in the Oban job so LLM failures retry" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Extract all turns since a watermark (stop losing mid-burst turns)

The debounce pushes `extraction_due_at` forward on every user message, then extraction covers only the latest turn. Add a `last_extracted_message_at` watermark on Conversation, pair ALL complete turns since it, and pass them to the action in one LLM call.

**Files:**
- Modify: `lib/magus/chat/conversation.ex` (new attribute + `mark_extracted` update action)
- Modify: `lib/magus/chat/chat.ex:276` (new code interface define, next to `define :schedule_extraction`)
- Modify: `lib/magus/chat/conversation/changes/extract_turn_memories.ex` (watermark-based loading + pairing)
- Modify: `lib/magus/agents/actions/extract_turn_memories.ex` (accept `turns` list; multi-turn prompt)
- Modify: `test/support/eval/subject/live.ex` (ingest via chunked turns)
- Test: `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs` (extend)
- Test: `test/magus/agents/actions/extract_turn_memories_test.exs` (extend)

**Interfaces:**
- Consumes: the change structure from Task 2 (`run_extraction/1` returning `:ok | {:error, reason}`).
- Produces:
  - `Conversation.last_extracted_message_at :: utc_datetime_usec | nil` attribute; update action `:mark_extracted` accepting it; code interface `Magus.Chat.mark_conversation_extracted(conversation, %{last_extracted_message_at: dt}, opts)`.
  - Public `Magus.Chat.Conversation.Changes.ExtractTurnMemories.pair_turns/1`: takes `[%{role: :user | :agent, text: String.t(), inserted_at: DateTime.t()}]` sorted ascending, returns `[%{user: String.t(), agent: String.t(), last_inserted_at: DateTime.t()}]` (complete pairs only).
  - `ExtractTurnMemories` action param `turns :: [%{"user" => String.t(), "agent" => String.t()}] | nil` (legacy `user_message`/`agent_response` still accepted and converted internally).

- [ ] **Step 1: Add the watermark attribute and action to Conversation**

In `lib/magus/chat/conversation.ex`, next to `:extraction_due_at` (line 855), add (mirror the exact options `:extraction_due_at` uses, typically `allow_nil?: true, public?: false`):

```elixir
    attribute :last_extracted_message_at, :utc_datetime_usec do
      allow_nil? true
      public? false
      description "Watermark: inserted_at of the newest message already covered by turn memory extraction"
    end
```

Next to the existing update action that does `accept [:extraction_due_at]` (line 185), add:

```elixir
    update :mark_extracted do
      accept [:last_extracted_message_at]
    end
```

Also extend the existing policy bypass for the extraction pipeline (line 700, `bypass action(:extract_turn_memories)`) with a sibling entry so the system can call it (copy the exact bypass style used there):

```elixir
    bypass action(:mark_extracted) do
      authorize_if Magus.Checks.IsAiAgent
      authorize_if always()
    end
```

If the existing `:extract_turn_memories` bypass uses a different authorizer body, mirror that body exactly instead.

- [ ] **Step 2: Add the code interface**

In `lib/magus/chat/chat.ex` next to line 276 (`define :schedule_extraction, ...`):

```elixir
      define :mark_conversation_extracted, action: :mark_extracted
```

- [ ] **Step 3: Generate and run the migration**

Run:
```bash
mix ash.codegen add_extraction_watermark
mix ash.migrate
```
Expected: one migration adding `last_extracted_message_at` to `conversations`. Inspect the generated file to confirm it ONLY adds this column (no unrelated drift). If unrelated changes appear, stop and resolve them first.

- [ ] **Step 4: Write failing tests for pairing and windowed extraction**

Append to `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`:

```elixir
  alias Magus.Chat.Conversation.Changes.ExtractTurnMemories, as: Change

  describe "pair_turns/1" do
    defp msg(role, text, seconds) do
      %{role: role, text: text, inserted_at: DateTime.add(~U[2026-07-04 10:00:00.000000Z], seconds, :second)}
    end

    test "pairs each user message with the next agent message, ascending order" do
      turns =
        Change.pair_turns([
          msg(:user, "q1", 0),
          msg(:agent, "a1", 1),
          msg(:user, "q2", 2),
          msg(:agent, "a2", 3)
        ])

      assert [%{user: "q1", agent: "a1"}, %{user: "q2", agent: "a2"}] =
               Enum.map(turns, &Map.take(&1, [:user, :agent]))

      assert List.last(turns).last_inserted_at == DateTime.add(~U[2026-07-04 10:00:00.000000Z], 3, :second)
    end

    test "drops a trailing user message without a response and empty-text messages" do
      turns =
        Change.pair_turns([
          msg(:agent, "stray", 0),
          msg(:user, "q1", 1),
          msg(:agent, "", 2),
          msg(:agent, "a1", 3),
          msg(:user, "pending", 4)
        ])

      assert [%{user: "q1", agent: "a1"}] = Enum.map(turns, &Map.take(&1, [:user, :agent]))
    end
  end

  describe "windowed extraction" do
    test "extracts every turn since the watermark and advances it" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      seed_turn!(conv, String.duplicate("First fact: I use Elixir daily. ", 3), String.duplicate("Understood, Elixir it is for everything we build. ", 3))
      seed_turn!(conv, String.duplicate("Second fact: deploys go to Fly.io. ", 3), String.duplicate("Got it, deployments target Fly.io from now on. ", 3))

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "First fact"
        assert prompt =~ "Second fact"
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} = run_extract_action(conv)

      {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, authorize?: false)
      refute is_nil(reloaded.last_extracted_message_at)
    end

    test "second run only sees turns after the watermark" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      seed_turn!(conv, String.duplicate("Old turn about project alpha. ", 3), String.duplicate("Acknowledged the alpha project details completely. ", 3))

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} = run_extract_action(conv)

      seed_turn!(conv, String.duplicate("New turn about project beta. ", 3), String.duplicate("Acknowledged the beta project details completely. ", 3))

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "beta"
        refute prompt =~ "alpha"
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, authorize?: false)
      assert {:ok, _} = run_extract_action(reloaded)
    end
  end
```

Note: `Ash.Seed.seed!` assigns `inserted_at` at insert time; consecutive seeds get monotonically increasing microsecond timestamps, which is what the watermark comparison needs. If two seeds collide on the same microsecond, add `Process.sleep(1)` between `seed_turn!` calls.

- [ ] **Step 5: Run tests to verify they fail**

Run: `mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`
Expected: FAIL with `function Magus.Chat.Conversation.Changes.ExtractTurnMemories.pair_turns/1 is undefined`.

- [ ] **Step 6: Implement watermark loading + pairing in the change**

In `lib/magus/chat/conversation/changes/extract_turn_memories.ex`, replace `run_extraction/1` and `load_last_turn/1` with:

```elixir
  # First extraction on a conversation with no watermark: cap the bootstrap
  # window so we do not extract an entire long history in one call.
  @max_bootstrap_messages 20
  # Below this many characters across all pending turns there is nothing
  # worth an LLM call; advance the watermark and move on.
  @min_transcript_chars 80

  defp run_extraction(conversation) do
    turns = load_turns_since(conversation)

    transcript_chars =
      Enum.reduce(turns, 0, fn t, acc ->
        acc + String.length(t.user) + String.length(t.agent)
      end)

    cond do
      turns == [] ->
        :ok

      transcript_chars < @min_transcript_chars ->
        advance_watermark(conversation, turns)

      true ->
        allow_global = agent_allows_global_writes?(conversation)

        case ExtractAction.run(
               %{
                 user_id: to_string(conversation.user_id),
                 conversation_id: to_string(conversation.id),
                 turns: Enum.map(turns, fn t -> %{"user" => t.user, "agent" => t.agent} end),
                 allow_global_memories: allow_global
               },
               %{}
             ) do
          {:ok, _result} -> advance_watermark(conversation, turns)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp advance_watermark(conversation, turns) do
    last = turns |> List.last() |> Map.fetch!(:last_inserted_at)

    case Magus.Chat.mark_conversation_extracted(
           conversation,
           %{last_extracted_message_at: last},
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_turns_since(conversation) do
    require Ash.Query

    query =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation.id and role in [:user, :agent])
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case conversation.last_extracted_message_at do
        nil -> query
        watermark -> Ash.Query.filter(query, inserted_at > ^watermark)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, messages} ->
        messages
        |> bootstrap_cap(conversation.last_extracted_message_at)
        |> Enum.map(&%{role: &1.role, text: &1.text || "", inserted_at: &1.inserted_at})
        |> pair_turns()

      {:error, _} ->
        []
    end
  end

  defp bootstrap_cap(messages, nil), do: Enum.take(messages, -@max_bootstrap_messages)
  defp bootstrap_cap(messages, _watermark), do: messages

  @doc """
  Pairs each user message with the next non-empty agent message. Input must
  be sorted ascending by inserted_at. Returns complete pairs only: a trailing
  user message without a response stays before the watermark and is picked up
  by the next run. Public for unit testing.
  """
  def pair_turns(messages), do: do_pair(messages, [])

  defp do_pair([], acc), do: Enum.reverse(acc)

  defp do_pair([%{role: :user, text: user_text} | rest], acc) when user_text != "" do
    case Enum.split_while(rest, fn m -> m.role != :agent or m.text == "" end) do
      {_skipped, [%{role: :agent, text: agent_text, inserted_at: at} | tail]} ->
        do_pair(tail, [%{user: user_text, agent: agent_text, last_inserted_at: at} | acc])

      {_skipped, []} ->
        Enum.reverse(acc)
    end
  end

  defp do_pair([_other | rest], acc), do: do_pair(rest, acc)
```

Delete the now-unused `load_last_turn/1`.

- [ ] **Step 7: Accept `turns` in the action and build a multi-turn prompt**

In `lib/magus/agents/actions/extract_turn_memories.ex`:

1. Change the schema (note the `{:or, [..., nil]}` rule):

```elixir
    schema: [
      user_id: [type: :string, required: true, doc: "User ID"],
      conversation_id: [type: :string, required: true, doc: "Conversation ID"],
      user_message: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Legacy single-turn user text (use turns instead)"
      ],
      agent_response: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Legacy single-turn agent text (use turns instead)"
      ],
      turns: [
        type: {:or, [{:list, :map}, nil]},
        default: nil,
        doc: ~s(List of turn pairs: [%{"user" => text, "agent" => text}])
      ],
      model: [type: {:or, [:string, nil]}, default: nil, doc: "Model key override"],
      allow_global_memories: [
        type: :boolean,
        default: true,
        doc: "Whether global memory extraction is allowed"
      ]
    ]
```

2. In `run/2`, after `params = normalize_keys(params)`, resolve turns and replace the short-message cond branch:

```elixir
    turns = resolve_turns(params)

    transcript_chars =
      Enum.reduce(turns, 0, fn t, acc ->
        acc + String.length(t["user"] || "") + String.length(t["agent"] || "")
      end)
```

Replace the branch `String.length(user_message) < 50 or String.length(agent_response) < 100 ->` with:

```elixir
      turns == [] or transcript_chars < 80 ->
        Logger.debug("ExtractTurnMemories: Transcript too short, skipping")
        {:ok, %{extractions_applied: 0, extractions_skipped: 0}}
```

and pass `turns` through `extract_and_apply/6` in place of `user_message, agent_response` (rename the two parameters to a single `turns`). Add:

```elixir
  defp resolve_turns(params) do
    case params["turns"] do
      turns when is_list(turns) and turns != [] ->
        Enum.map(turns, fn t ->
          %{"user" => to_string(t["user"] || t[:user] || ""), "agent" => to_string(t["agent"] || t[:agent] || "")}
        end)

      _ ->
        user_message = params["user_message"] || ""
        agent_response = params["agent_response"] || ""

        if user_message == "" and agent_response == "" do
          []
        else
          [%{"user" => user_message, "agent" => agent_response}]
        end
    end
  end
```

3. In `build_prompt/4` replace the `## Current Turn` section with:

```elixir
    ## Current Turns

    #{format_turns(turns)}
```

and add:

```elixir
  defp format_turns(turns) do
    Enum.map_join(turns, "\n\n---\n\n", fn t ->
      "**User**: #{t["user"]}\n\n**Assistant**: #{t["agent"]}"
    end)
  end
```

Also update the instruction line `Extract any information worth remembering from this turn:` to `Extract any information worth remembering from these turns:`.

4. Update the moduledoc usage example to show the `turns` param.

- [ ] **Step 8: Update the eval subject to use turns (chunked like production bursts)**

In `test/support/eval/subject/live.ex`, replace `ingest/2` and `force_extract/3`:

```elixir
  # Production extraction batches all turns accumulated during a debounce
  # window into one call; approximate that burst size with chunks of 5.
  @turns_per_extraction 5

  @impl true
  def ingest(ctx, items) do
    items
    |> pair_turns()
    |> Enum.map(fn {user_text, agent_text} -> %{"user" => user_text, "agent" => agent_text} end)
    |> Enum.chunk_every(@turns_per_extraction)
    |> Enum.each(fn turns -> force_extract(ctx, turns) end)

    settle_extraction()
    {:ok, ctx}
  end

  defp force_extract(ctx, turns) do
    Magus.Agents.Actions.ExtractTurnMemories.run(
      %{
        user_id: to_string(ctx.user.id),
        conversation_id: to_string(ctx.conversation.id),
        turns: turns,
        allow_global_memories: true
      },
      %{}
    )
  rescue
    e ->
      Logger.warning("Subject.Live force_extract failed: #{Exception.message(e)}")
      :ok
  end
```

- [ ] **Step 9: Update the existing action test expectations**

In `test/magus/agents/actions/extract_turn_memories_test.exs`, the test `"skips extraction for very short messages"` still passes (7 chars total is below 80). Add one new test in the same describe block:

```elixir
    test "extracts from a multi-turn window" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "turn one about the Magus project"
        assert prompt =~ "turn two about preferring Elixir"

        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      result =
        ExtractTurnMemories.run(
          %{
            user_id: user.id,
            conversation_id: conv.id,
            turns: [
              %{"user" => "This is turn one about the Magus project and its goals in detail.", "agent" => "Understood, the Magus project goals are noted here."},
              %{"user" => "This is turn two about preferring Elixir for everything we do.", "agent" => "Elixir preference recorded for future work sessions."}
            ]
          },
          %{}
        )

      assert {:ok, %{extractions_applied: 0}} = result
    end
```

- [ ] **Step 10: Run the full memory test surface**

Run: `mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs test/magus/agents/actions/extract_turn_memories_test.exs test/magus/agents/reactors/extract_memories_test.exs`
Expected: PASS. If the reactor test calls the action with the legacy pair params, it passes unchanged through `resolve_turns/1`.

- [ ] **Step 11: Commit**

```bash
git add lib/magus/chat/conversation.ex lib/magus/chat/chat.ex lib/magus/chat/conversation/changes/extract_turn_memories.ex lib/magus/agents/actions/extract_turn_memories.ex test/support/eval/subject/live.ex test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs test/magus/agents/actions/extract_turn_memories_test.exs priv/repo/migrations priv/resource_snapshots
git commit -m "feat(memory): extract all turns since a watermark instead of only the latest pair" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Full name index for dedup context + explicit replace mode for contradictions

The extractor sees only 10 recent memories, so "use the exact same name" misses and near-duplicates pile up. Contradictions can only deep-merge, so stale keys persist. Show all active names/summaries (capped at 100 per scope) and add `update_mode: "merge" | "replace"` to the extraction schema.

**Files:**
- Modify: `lib/magus/agents/actions/extract_turn_memories.ex`
- Test: `test/magus/agents/actions/extract_turn_memories_test.exs` (extend)

**Interfaces:**
- Consumes: `Memory.set_memory(memory, content, %{summary: summary}, actor:)` (existing; content passed is written as-is by the `:set` action, merging is caller-side).
- Produces: normalized extraction maps now carry `"update_mode"` (`"merge"` default).

- [ ] **Step 1: Write the failing test**

Append to the `describe "run/2"` block:

```elixir
    test "replace mode overwrites content instead of merging" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, existing} =
        Magus.Memory.create_memory(
          conv.id,
          user.id,
          "Editor Preference",
          %{content: %{"editor" => "vim", "reason" => "muscle memory"}, summary: "Prefers vim"},
          actor: user
        )

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "extractions" => [
            %{
              "name" => "Editor Preference",
              "summary" => "Prefers VS Code now",
              "content" => %{"editor" => "vscode"},
              "scope" => "local",
              "update_mode" => "replace",
              "reason" => "User switched editors, superseding the old preference"
            }
          ]
        })
      end)

      assert {:ok, %{extractions_applied: 1}} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   turns: [
                     %{
                       "user" => "Actually I switched to VS Code full time, forget the vim setup entirely.",
                       "agent" => "Noted, VS Code is your editor from now on, replacing the vim preference."
                     }
                   ]
                 },
                 %{}
               )

      {:ok, reloaded} = Magus.Memory.get_memory(existing.id, actor: user)
      assert reloaded.content == %{"editor" => "vscode"}
      refute Map.has_key?(reloaded.content, "reason")
    end

    test "shows more than 10 existing memory names to the extractor" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for i <- 1..15 do
        {:ok, _} =
          Magus.Memory.create_memory(
            conv.id,
            user.id,
            "Fact #{i}",
            %{content: %{}, summary: "Summary #{i}"},
            actor: user
          )
      end

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "Fact 1"
        # With the old take(10) recency cap, the oldest names fell out.
        assert Enum.all?(1..15, fn i -> prompt =~ "Fact #{i}" end)
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   turns: [
                     %{
                       "user" => "Here is a sufficiently long user message about ongoing project work.",
                       "agent" => "Here is a sufficiently long agent response acknowledging the project work."
                     }
                   ]
                 },
                 %{}
               )
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/magus/agents/actions/extract_turn_memories_test.exs`
Expected: FAIL. Replace test fails because content merges (`"reason"` key survives); name index test fails on the 10-memory cap.

- [ ] **Step 3: Implement**

In `lib/magus/agents/actions/extract_turn_memories.ex`:

1. Raise the caps in `load_local_memories/1` and `load_user_memories/2`: change `Enum.take(memories, 10)` to `Enum.take(memories, 100)` in both.

2. Add `update_mode` to `@output_schema` item properties:

```elixir
            "update_mode" => %{
              "type" => "string",
              "enum" => ["merge", "replace"],
              "description" => "merge (default): add fields into the existing memory. replace: the new content supersedes the old entirely."
            }
```

(Do not add it to `"required"`.)

3. In `normalize_extraction/1` add:

```elixir
      "update_mode" => normalize_update_mode(extraction["update_mode"] || extraction[:update_mode])
```

and:

```elixir
  defp normalize_update_mode("replace"), do: "replace"
  defp normalize_update_mode(_), do: "merge"
```

4. Thread `update_mode` into the apply path. In `apply_extraction/5` read `update_mode = extraction["update_mode"]` and pass it to `apply_local_extraction/6` and `apply_user_extraction/6`. In every place that currently computes `merged = merge_content(existing_or_memory.content, content)`, replace with:

```elixir
        new_content = resolve_content(memory.content, content, update_mode)
```

and add one helper:

```elixir
  defp resolve_content(_old, new, "replace"), do: new
  defp resolve_content(old, new, _merge), do: merge_content(old, new)
```

There are four call sites: name-match update (local + user) and dedup-match update (local + user). All four must use `resolve_content/3`.

5. Extend the prompt instructions (in `build_prompt`) after the "use the exact same name" line:

```
    Set update_mode when updating an existing memory:
    - "merge" (default): new fields are added to the memory
    - "replace": the new content fully supersedes the old. Use this when the
      new information contradicts or reverses what the memory currently says
      (changed preference, reversed decision, corrected fact).
```

6. Add to the system prompt's "Focus on" list: `- Contradictions of existing memories (extract with update_mode "replace")`.

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/agents/actions/extract_turn_memories_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/actions/extract_turn_memories.ex test/magus/agents/actions/extract_turn_memories_test.exs
git commit -m "feat(memory): full name index for extraction dedup + explicit replace mode for contradictions" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Stop refreshing the decay clock on ambient injection

`ConsolidateMemories` decays memories idle for 90 days via `COALESCE(last_accessed_at, updated_at)`, but `BuildMemoryContext` bumps `last_accessed_at` for EVERY memory it injects, including the top-3-by-recency layer that is injected every single turn. Result: ambient injection makes decay unreachable. Only semantically retrieved memories (selected by relevance to the actual query) should count as "accessed". The `search_memories` tool already touches its own results and stays unchanged.

**Files:**
- Modify: `lib/magus/agents/actions/build_memory_context.ex:146-147` and `:505-511`
- Test: `test/magus/agents/actions/build_memory_context_test.exs` (create if absent, else extend)

**Interfaces:**
- Consumes: `Magus.Memory.touch_accessed/1` (unchanged).
- Produces: no interface change; behavioral contract is "key/associated layers never touch `last_accessed_at`".

- [ ] **Step 1: Write the failing test**

Create (or extend) `test/magus/agents/actions/build_memory_context_test.exs`:

```elixir
defmodule Magus.Agents.Actions.BuildMemoryContextTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Actions.BuildMemoryContext

  test "ambient (key-layer) injection does not bump last_accessed_at" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    {:ok, memory} =
      Magus.Memory.create_memory(
        conv.id,
        user.id,
        "Ambient Memory",
        %{content: %{}, summary: "Injected by recency every turn"},
        actor: user
      )

    assert is_nil(memory.last_accessed_at)

    # Empty query_text skips the semantic layer entirely, so the only
    # retrieval is the ambient key layer.
    {:ok, context} =
      BuildMemoryContext.build(%{
        user_id: to_string(user.id),
        conversation_id: to_string(conv.id),
        query_text: "",
        global_enabled: false
      })

    assert Enum.any?(context.important, &(&1.id == memory.id))

    {:ok, reloaded} = Magus.Memory.get_memory(memory.id, actor: user)
    assert is_nil(reloaded.last_accessed_at)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/actions/build_memory_context_test.exs`
Expected: FAIL on the final assertion (`last_accessed_at` gets bumped today). Note: the touch is synchronous (`touch_accessed_memories` is not in a Task), so no race.

- [ ] **Step 3: Implement**

In `lib/magus/agents/actions/build_memory_context.ex`, replace lines 146-147:

```elixir
    # Bump last_accessed_at only for semantically retrieved memories: they
    # were selected by relevance to the actual query, which is a real usage
    # signal. Key (recency) and associated memories are injected ambiently
    # every turn; touching them would make the 90-day decay in
    # ConsolidateMemories self-refreshing and unreachable.
    touch_accessed_memories(Enum.map(semantic, & &1.id))
```

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/agents/actions/build_memory_context_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/actions/build_memory_context.ex test/magus/agents/actions/build_memory_context_test.exs
git commit -m "fix(memory): only semantic retrieval refreshes the decay clock, not ambient injection" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Association weight decay + unbiased reinforcement sampling

Hebbian weights only ever increase (+0.1 per co-retrieval, capped at 1.0), so at steady state ordering degrades to noise. Add read-time exponential decay (half-life 30 days) so unreinforced edges fade. Also fix the reinforcement pair cap: `Enum.take(pairs, 10)` systematically favors low-UUID pairs; sample randomly instead. Fold in the `touch_accessed` TODO comment cleanup.

**Files:**
- Modify: `lib/magus/memory/memory_association.ex` (add `effective_weight/2`)
- Modify: `lib/magus/agents/actions/build_memory_context.ex` (`expand_associations/1`, `reinforce_co_retrieved/1`)
- Modify: `lib/magus/memory/memory.ex:24` (comment only)
- Test: `test/magus/memory/memory_association_decay_test.exs` (new)

**Interfaces:**
- Produces: `Magus.Memory.MemoryAssociation.effective_weight(assoc, now \\ DateTime.utc_now()) :: float` where `assoc` needs `weight` and `last_reinforced_at` fields. No stored-weight semantics change (decay is read-time only; reinforcement still bumps the stored weight).

- [ ] **Step 1: Write the failing test**

Create `test/magus/memory/memory_association_decay_test.exs`:

```elixir
defmodule Magus.Memory.MemoryAssociationDecayTest do
  use ExUnit.Case, async: true

  alias Magus.Memory.MemoryAssociation

  @now ~U[2026-07-04 12:00:00.000000Z]

  defp assoc(weight, days_ago) do
    %{weight: weight, last_reinforced_at: DateTime.add(@now, -days_ago * 86_400, :second)}
  end

  test "freshly reinforced weight is undecayed" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 0), @now), 0.8, 0.001
  end

  test "weight halves after one 30-day half-life" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 30), @now), 0.4, 0.001
  end

  test "weight quarters after two half-lives" do
    assert_in_delta MemoryAssociation.effective_weight(assoc(0.8, 60), @now), 0.2, 0.001
  end

  test "future last_reinforced_at (clock skew) never amplifies above stored weight" do
    assert MemoryAssociation.effective_weight(assoc(0.8, -1), @now) <= 0.8
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/memory/memory_association_decay_test.exs`
Expected: FAIL with `effective_weight/2 is undefined`.

- [ ] **Step 3: Implement `effective_weight/2`**

In `lib/magus/memory/memory_association.ex`, below the `require Ash.Query` line, add:

```elixir
  @half_life_days 30.0

  @doc """
  Time-decayed effective weight: the stored weight halves for every
  #{trunc(@half_life_days)} days since the edge was last reinforced. Decay is
  computed at read time; the stored weight is never rewritten. Clock skew
  (future last_reinforced_at) is clamped so the result never exceeds the
  stored weight.
  """
  def effective_weight(%{weight: weight, last_reinforced_at: at}, now \\ DateTime.utc_now()) do
    days = max(DateTime.diff(now, at, :second), 0) / 86_400
    weight * :math.pow(0.5, days / @half_life_days)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/magus/memory/memory_association_decay_test.exs`
Expected: PASS.

- [ ] **Step 5: Use effective weight in association expansion and sample reinforcement pairs**

In `lib/magus/agents/actions/build_memory_context.ex`:

1. Add near the other module attributes (lines 35-37):

```elixir
  @min_effective_assoc_weight 0.05
```

2. In `expand_associations/1`, replace the `assocs |> Enum.flat_map(...)` pipeline (lines 321-332) with:

```elixir
          now = DateTime.utc_now()

          assocs
          |> Enum.flat_map(fn a ->
            ew = Magus.Memory.MemoryAssociation.effective_weight(a, now)

            cond do
              ew < @min_effective_assoc_weight -> []
              MapSet.member?(memory_ids, a.memory_a_id) -> [{a.memory_b_id, ew}]
              MapSet.member?(memory_ids, a.memory_b_id) -> [{a.memory_a_id, ew}]
              true -> []
            end
          end)
          |> Enum.reject(fn {id, _w} -> MapSet.member?(memory_ids, id) end)
          |> Enum.uniq_by(fn {id, _w} -> id end)
          |> Enum.sort_by(fn {_id, w} -> w end, :desc)
          |> Enum.take(@max_associated_results)
          |> Enum.map(fn {id, _w} -> id end)
```

3. In `reinforce_co_retrieved/1`, replace `|> Enum.take(@max_reinforcement_pairs)` with:

```elixir
      # take_random instead of take: with >10 pairs, a deterministic prefix
      # systematically reinforces the same low-UUID pairs every turn.
      |> Enum.take_random(@max_reinforcement_pairs)
```

4. In `lib/magus/memory/memory.ex` line 24, replace `# TODO: clean me up` with:

```elixir
  # Intentionally raw SQL: this must NOT run through the :set/:deactivate
  # actions, which would create a MemoryVersion, broadcast PubSub, and bump
  # lock_version on every ambient retrieval.
```

- [ ] **Step 6: Run the surrounding tests**

Run: `mix test test/magus/memory test/magus/agents/actions/build_memory_context_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/memory/memory_association.ex lib/magus/memory/memory.ex lib/magus/agents/actions/build_memory_context.ex test/magus/memory/memory_association_decay_test.exs
git commit -m "feat(memory): read-time association decay (30d half-life) + random reinforcement sampling" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Memory block token budget + drop the information-free confidence label

Nine key memories can each carry 2000 chars of content JSON (~18k chars of system prompt worst case), and confidence is rendered but always 1.0. Cap per-memory previews at 600 chars, add a 6000-char whole-block budget with a summary-only fallback pass, and remove the confidence label.

**Files:**
- Modify: `lib/magus/agents/actions/build_memory_context.ex` (formatting section, lines 389-503)
- Test: `test/magus/agents/actions/build_memory_context_format_test.exs` (new)

**Interfaces:**
- Produces: `BuildMemoryContext.format_context(important, semantic, global_enabled, opts \\ [])` becomes public (`@doc false`) with `opts[:previews]` boolean (default true). Memories passed in are maps/structs with `name`, `summary`, `content`, `display_scope`, optional `kind`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/actions/build_memory_context_format_test.exs`:

```elixir
defmodule Magus.Agents.Actions.BuildMemoryContextFormatTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Actions.BuildMemoryContext

  defp mem(name, opts \\ []) do
    %{
      name: name,
      summary: Keyword.get(opts, :summary, "summary of #{name}"),
      content: Keyword.get(opts, :content, %{}),
      display_scope: Keyword.get(opts, :scope, :local),
      kind: Keyword.get(opts, :kind, :general),
      confidence: Keyword.get(opts, :confidence, 0.7)
    }
  end

  test "confidence is never rendered" do
    out = BuildMemoryContext.format_context([mem("A", confidence: 0.7)], [], true)
    refute out =~ "confidence"
  end

  test "content previews are capped at 600 chars" do
    big = %{"data" => String.duplicate("x", 3000)}
    out = BuildMemoryContext.format_context([mem("A", content: big)], [], true)
    assert out =~ "(truncated)"

    [_, preview] = String.split(out, "```json", parts: 2)
    [preview, _] = String.split(preview, "```", parts: 2)
    assert String.length(preview) <= 700
  end

  test "previews: false omits content JSON entirely" do
    big = %{"data" => String.duplicate("x", 3000)}
    out = BuildMemoryContext.format_context([mem("A", content: big)], [], true, previews: false)
    refute out =~ "```json"
    assert out =~ "search_memories"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/actions/build_memory_context_format_test.exs`
Expected: FAIL (`format_context/3` is private; UndefinedFunctionError).

- [ ] **Step 3: Implement**

In `lib/magus/agents/actions/build_memory_context.ex`:

1. Add module attributes:

```elixir
  @max_preview_chars 600
  @max_block_chars 6000
```

2. Make the formatter public and previews-aware. Replace `defp format_context(important, semantic, global_enabled)` (and its empty-clause sibling) with:

```elixir
  @doc false
  def format_context(important, semantic, global_enabled, opts \\ [])

  def format_context([], [], _global_enabled, _opts), do: ""

  def format_context(important, semantic, global_enabled, opts) do
    previews? = Keyword.get(opts, :previews, true)

    sections = [
      format_important_section(important, previews?),
      format_semantic_section(semantic),
      format_global_note(global_enabled, important ++ semantic)
    ]
    # ... rest identical to today's format_context body
  end
```

3. Thread `previews?` through: `format_important_section(memories, previews?)` maps with `&format_important_memory(&1, previews?)`. In `format_important_memory/2`:
   - Delete the `confidence` and `confidence_label` bindings and remove `#{confidence_label}` from the heredoc.
   - `content_preview = if previews?, do: format_content_preview(memory.content), else: ""`

4. In `format_content_preview/1` change the cap from 2000/1900 to `@max_preview_chars`/`@max_preview_chars - 100`:

```elixir
    truncated =
      if String.length(content_json) > @max_preview_chars do
        String.slice(content_json, 0, @max_preview_chars - 100) <> "\n... (truncated)"
      else
        content_json
      end
```

5. In `build_context/6`, apply the budget where `formatted` is computed (line 144):

```elixir
    formatted = format_context(important, semantic ++ associated, global_enabled)

    # Whole-block budget: if full previews blow past the cap, re-render
    # summary-only. Full content stays reachable via the search_memories tool.
    formatted =
      if String.length(formatted) > @max_block_chars do
        format_context(important, semantic ++ associated, global_enabled, previews: false)
      else
        formatted
      end
```

The closing line `You can search for more context with \`search_memories\`.` already satisfies the `previews: false` test assertion.

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/agents/actions/build_memory_context_format_test.exs test/magus/agents/actions/build_memory_context_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/actions/build_memory_context.ex test/magus/agents/actions/build_memory_context_format_test.exs
git commit -m "feat(memory): budget the injected memory block and drop the dead confidence label" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Full verification

**Files:** none new.

- [ ] **Step 1: Run precommit**

Run: `mix precommit`
Expected: compile with warnings-as-errors clean, format clean, non-e2e tests green. Fix anything that surfaces before proceeding.

- [ ] **Step 2: Warnings-as-errors under test env**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: no warnings. (Per-edit hooks do not catch these; CI does.)

- [ ] **Step 3: Commit any fixups**

```bash
git add -A lib test
git commit -m "chore(memory): precommit fixups for memory hardening" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
Skip the commit if the tree is clean.

---

### Task 9: Post-hardening eval run and comparison

**Files:**
- Modify: `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`

**Interfaces:**
- Consumes: the baseline section written in Task 1. Identical run parameters are mandatory (`--limit 60`, Live subject, same judge default).

- [ ] **Step 1: Run the post-hardening eval**

Run:
```bash
set -a && source .env && set +a
MIX_ENV=test mix magus.eval longmemeval --limit 60
```
Expected: aggregate + scoreboard line printed.

- [ ] **Step 2: Extract per-ability numbers**

Run the same jq command as Task 1 Step 3 against the new last row of `eval/results/longmemeval.jsonl`.

- [ ] **Step 3: Append the comparison to the baselines doc**

Append a section:

```markdown
## Post-hardening (extraction window + retry + replace mode + decay fixes)

- Date: <date>
- Git SHA: <sha>
- Aggregate: <value> (baseline: <baseline value>, delta: <+/->)
- Per ability (with baseline deltas):
  | ability | total | correct | accuracy | baseline accuracy | delta |
  |---|---|---|---|---|---|
  | <fill> | | | | | |

### Reading
<2-4 sentences: did knowledge-update and multi-session move as predicted?
Any regressions? If aggregate regressed, name the suspect task and file a
follow-up before merging.>
```

Every `<...>` filled from real output. If the aggregate regressed by more than 0.03, STOP and investigate before merging: bisect by re-running with `git stash` of the most suspect change (Task 4's prompt changes are the most likely culprit for regressions).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-07-04-memory-eval-baselines.md eval/results
git commit -m "docs(eval): post-hardening LongMemEval-S results and baseline comparison" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
