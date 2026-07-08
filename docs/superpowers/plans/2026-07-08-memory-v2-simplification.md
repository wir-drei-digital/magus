# Memory v2: Repair + Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the workspace-bucket bug and scope over-assignment in the memory system, then remove the dead machinery (associations, memory versions, sources, confidence, structured_data, soft-delete, decay, promotion) per the approved spec.

**Architecture:** Memory becomes a lean relevance layer: extraction writes conversation-local rows only; the nightly profile distiller is the sole ambient curator of durable facts; the user bucket holds only explicit writes; hard deletes with Super Brain retraction replace soft-delete. Spec: `docs/superpowers/specs/2026-07-08-memory-v2-simplification-design.md` (read it for rationale; this plan is self-contained for execution).

**Tech Stack:** Elixir/Phoenix, Ash 3.x + AshPostgres (+ AshOban, AshTypescript), Oban, pgvector, FalkorDB via `Magus.Graph`, Svelte 5 SPA in `frontend/`.

## Global Constraints

- Work on the feature branch in the worktree; commit after every task with scoped paths (`git commit -- <paths>`), never bare `git add .` + commit (a shared beads index auto-stages files).
- NEVER run `mix ash.reset` (wipes data). Migrations run only in Task 13, only against test partitions.
- Tests run with `MIX_ENV=test mix test <path>` after `set -a && source .env && set +a` is NOT required for unit tests (only live e2e). Use a partition DB if the default is in use: `MIX_TEST_PARTITION=_memv2 MIX_ENV=test mix ash.setup` once, then prefix test commands with `MIX_TEST_PARTITION=_memv2`.
- Do not run bare `mix compile` outside MIX_ENV=test while a dev server runs; use `MIX_ENV=test mix compile --warnings-as-errors`.
- German localization and classic-workbench LiveView code are out of scope; do not touch `lib/magus_web/`.
- No em dashes in any prose you write (docs, comments, commit messages).
- Every task: run the named tests, then commit. Implementers report actual test output.
- The AI actor for memory writes is `%Magus.Agents.Support.AiAgent{}` (`ai_actor()` helper in tools).
- Known pre-existing failures on main: some Super Brain integration tests assume empty tables and may fail on shared DBs. Scope assertions to rows you created. If a failure is clearly unrelated to your change (leaked rows, FalkorDB not running on :6380), note it in your report instead of chasing it.

---

## Phase 1: Correctness (no migrations)

### Task 1: Tagged workspace lookup on the Memory domain

**Files:**
- Modify: `lib/magus/memory/memory.ex` (the domain module; `workspace_id_for_conversation/1` is around line 63)
- Test: `test/magus/memory/memory_workspace_lookup_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.Chat.Conversation` (existing resource)
- Produces: `Magus.Memory.fetch_workspace_id_for_conversation(conversation_id) :: {:ok, workspace_id | nil} | {:error, :not_found}`. The existing nil-collapsing `workspace_id_for_conversation/1` stays (extraction still uses it); tools stop using it after Task 2.

- [ ] **Step 1: Write the failing test**

Create `test/magus/memory/memory_workspace_lookup_test.exs`:

```elixir
defmodule Magus.Memory.WorkspaceLookupTest do
  use Magus.DataCase, async: true

  import Magus.Generator

  alias Magus.Chat

  describe "fetch_workspace_id_for_conversation/1" do
    test "returns {:ok, workspace_id} for a workspace conversation" do
      user = generate(user())
      workspace = generate(workspace(owner_id: user.id))

      {:ok, conversation} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      assert {:ok, workspace_id} =
               Magus.Memory.fetch_workspace_id_for_conversation(conversation.id)

      assert workspace_id == workspace.id
    end

    test "returns {:ok, nil} for a personal conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} = Magus.Memory.fetch_workspace_id_for_conversation(conversation.id)
    end

    test "returns {:error, :not_found} for an unknown conversation id" do
      assert {:error, :not_found} =
               Magus.Memory.fetch_workspace_id_for_conversation(Ash.UUID.generate())
    end

    test "returns {:error, :not_found} for nil" do
      assert {:error, :not_found} = Magus.Memory.fetch_workspace_id_for_conversation(nil)
    end
  end
end
```

Note: check `test/support/generator.ex` for the exact `workspace(...)` generator name and arguments; other tests under `test/magus/memory/memory_workspace_test.exs` show the working pattern for creating a workspace + conversation. Adjust the two setup lines to match, keep the assertions.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `MIX_ENV=test mix test test/magus/memory/memory_workspace_lookup_test.exs`
Expected: FAIL with `function Magus.Memory.fetch_workspace_id_for_conversation/1 is undefined`

- [ ] **Step 3: Implement**

In `lib/magus/memory/memory.ex`, directly below the existing `workspace_id_for_conversation/1`:

```elixir
  @doc """
  Tagged variant of `workspace_id_for_conversation/1`.

  Distinguishes "personal conversation" ({:ok, nil}) from "conversation does
  not exist" ({:error, :not_found}) so tool callers can refuse to silently
  write to the personal bucket on a bad conversation id.
  """
  @spec fetch_workspace_id_for_conversation(String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :not_found}
  def fetch_workspace_id_for_conversation(nil), do: {:error, :not_found}

  def fetch_workspace_id_for_conversation(conversation_id) do
    require Ash.Query

    case Magus.Chat.Conversation
         |> Ash.Query.filter(id == ^conversation_id)
         |> Ash.Query.select([:workspace_id])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{workspace_id: ws}} -> {:ok, ws}
      {:ok, nil} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end
```

- [ ] **Step 4: Run the test, confirm it passes**

Run: `MIX_ENV=test mix test test/magus/memory/memory_workspace_lookup_test.exs`
Expected: 4 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/magus/memory/memory.ex test/magus/memory/memory_workspace_lookup_test.exs
git commit -m "feat(memory): tagged fetch_workspace_id_for_conversation lookup" -- lib/magus/memory/memory.ex test/magus/memory/memory_workspace_lookup_test.exs
```

---

### Task 2: `resolve_user_bucket/1` resolver in the memory tool helpers

**Files:**
- Modify: `lib/magus/agents/tools/memory/helpers.ex`
- Test: `test/magus/agents/tools/memory/helpers_test.exs` (create if absent; check for an existing file first and extend it)

**Interfaces:**
- Consumes: `Magus.Memory.fetch_workspace_id_for_conversation/1` (Task 1)
- Produces: `Magus.Agents.Tools.Memory.Helpers.resolve_user_bucket(ctx :: map()) :: {:ok, workspace_id | nil} | {:error, :conversation_not_found} | {:error, :no_bucket_context}`

Resolution contract (from the spec):
1. `conversation_id` present in ctx (atom or string key) and conversation exists: `{:ok, its workspace_id}` (nil means personal, which is legitimate).
2. `conversation_id` present but lookup fails: `{:error, :conversation_not_found}`.
3. No `conversation_id`: use `ctx.workspace_id` ONLY if the key is actually present (`Map.has_key?`, atom or string); a present nil is an explicit personal choice.
4. Neither key: `{:error, :no_bucket_context}`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Magus.Agents.Tools.Memory.HelpersTest do
  use Magus.DataCase, async: true

  import Magus.Generator

  alias Magus.Agents.Tools.Memory.Helpers
  alias Magus.Chat

  describe "resolve_user_bucket/1" do
    test "derives the bucket from a workspace conversation" do
      user = generate(user())
      workspace = generate(workspace(owner_id: user.id))
      {:ok, conv} = Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      assert {:ok, ws} = Helpers.resolve_user_bucket(%{conversation_id: conv.id})
      assert ws == workspace.id
    end

    test "derives nil (personal) from a personal conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} = Helpers.resolve_user_bucket(%{conversation_id: conv.id})
    end

    test "conversation takes precedence over a stale ctx workspace_id" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      assert {:ok, nil} =
               Helpers.resolve_user_bucket(%{
                 conversation_id: conv.id,
                 workspace_id: Ash.UUID.generate()
               })
    end

    test "invalid conversation id is an error, never a silent personal write" do
      assert {:error, :conversation_not_found} =
               Helpers.resolve_user_bucket(%{conversation_id: Ash.UUID.generate()})
    end

    test "falls back to an explicitly present workspace_id key" do
      ws = Ash.UUID.generate()
      assert {:ok, ^ws} = Helpers.resolve_user_bucket(%{workspace_id: ws})
    end

    test "a present nil workspace_id is an explicit personal choice" do
      assert {:ok, nil} = Helpers.resolve_user_bucket(%{workspace_id: nil})
    end

    test "string keys work" do
      ws = Ash.UUID.generate()
      assert {:ok, ^ws} = Helpers.resolve_user_bucket(%{"workspace_id" => ws})
    end

    test "no bucket context at all is an error" do
      assert {:error, :no_bucket_context} = Helpers.resolve_user_bucket(%{user_id: "x"})
    end
  end
end
```

- [ ] **Step 2: Run tests, confirm failure** (`function Helpers.resolve_user_bucket/1 is undefined`)

- [ ] **Step 3: Implement**

Add to `lib/magus/agents/tools/memory/helpers.ex`:

```elixir
  @doc """
  Resolve the user-memory workspace bucket for a tool invocation.

  The conversation is the source of truth: when the tool context carries a
  conversation_id, the bucket is that conversation's workspace (nil for a
  personal conversation), and a bad conversation id is an error rather than
  a silent fall-through to the personal bucket. Without a conversation, a
  workspace_id KEY must be present in the context (a present nil is an
  explicit personal choice).
  """
  @spec resolve_user_bucket(map()) ::
          {:ok, String.t() | nil}
          | {:error, :conversation_not_found}
          | {:error, :no_bucket_context}
  def resolve_user_bucket(ctx) when is_map(ctx) do
    conversation_id = Map.get(ctx, :conversation_id) || Map.get(ctx, "conversation_id")

    cond do
      is_binary(conversation_id) and conversation_id != "" ->
        case Magus.Memory.fetch_workspace_id_for_conversation(conversation_id) do
          {:ok, ws} -> {:ok, ws}
          {:error, :not_found} -> {:error, :conversation_not_found}
        end

      Map.has_key?(ctx, :workspace_id) ->
        {:ok, Map.get(ctx, :workspace_id)}

      Map.has_key?(ctx, "workspace_id") ->
        {:ok, Map.get(ctx, "workspace_id")}

      true ->
        {:error, :no_bucket_context}
    end
  end

  @doc "Human-readable tool error for a failed bucket resolution."
  def bucket_error_message(:conversation_not_found),
    do: "Could not resolve the conversation for this memory operation. Try again."

  def bucket_error_message(:no_bucket_context),
    do: "Missing workspace context for a user-scoped memory operation."
```

- [ ] **Step 4: Run tests, confirm 8 pass**

- [ ] **Step 5: Commit**

```bash
git add lib/magus/agents/tools/memory/helpers.ex test/magus/agents/tools/memory/helpers_test.exs
git commit -m "feat(memory): resolve_user_bucket tool-context resolver" -- lib/magus/agents/tools/memory/helpers.ex test/magus/agents/tools/memory/helpers_test.exs
```

---

### Task 3: SetMemory uses the resolver, defaults to local scope

**Files:**
- Modify: `lib/magus/agents/tools/memory/set_memory.ex`
- Test: `test/magus/agents/tools/memory/set_memory_test.exs`

**Interfaces:**
- Consumes: `resolve_user_bucket/1` + `bucket_error_message/1` (Task 2)
- Produces: `set_memory` tool with `scope` default `"local"`; user-scope writes always land in the conversation's bucket.

- [ ] **Step 1: Update the schema default and description**

In the `use Jido.Action` block of `set_memory.ex`, replace the description and the scope param:

```elixir
    description: """
    Create or update a named memory. Use this when the user explicitly asks you to remember something.

    SCOPE determines where the memory lives:
    - "local" (default): Anything about this conversation or project.
      Examples: "Remember the deadline is Friday", "Note we chose option B".
    - "user": ONLY for durable facts the user explicitly wants everywhere, signalled
      by words like "always", "generally", "for all my projects", "remember this everywhere".
      Examples: "Always answer in German", "I generally prefer TypeScript".
    - "agent": Custom-agent-scoped memories, only available to a specific agent.

    When in doubt, use "local". Durable facts are consolidated automatically.
    If a memory with the same name already exists in the given scope, it will be updated.
    """,
```

and in the schema, the `scope` entry's `default:` becomes `"local"` (keep type and doc shape as-is, updating the doc string to name local as default).

- [ ] **Step 2: Wire the resolver into `run/2` and `create_memory` for user scope**

Replace the `required_fields`/`validate_context` section of `run/2` (currently `"user" -> [:user_id]`) and the user-scope create. The resolver runs for user scope only, after context validation, and the resolved bucket is put into ctx so `find_memory_by_name/3` (upsert lookup) sees the same bucket:

```elixir
      required_fields =
        case scope do
          "user" -> [:user_id]
          "agent" -> [:user_id, :custom_agent_id]
          _ -> [:user_id, :conversation_id]
        end

      with {:ok, ctx} <- validate_context(context, required_fields),
           {:ok, ctx} <- put_user_bucket(ctx, scope) do
        name = get_param(params, :name)
        summary = get_param(params, :summary)
        content = get_param(params, :content, %{}) |> ensure_map()

        confidence = get_param(params, :confidence)
        kind = get_param(params, :kind)
        structured_data = get_param(params, :structured_data)
        extra_attrs = build_extra_attrs(confidence, kind, structured_data)

        upsert_memory(name, summary, content, scope, ctx, extra_attrs)
      else
        {:error, message} -> {:ok, %{error: message}}
      end
```

(`build_extra_attrs/3` and the confidence/structured_data params stay untouched in this task; Task 12 removes them.)

with the new private helper:

```elixir
  # For user scope, resolve the workspace bucket from the conversation (the
  # tool context value is only a fallback) and pin it into ctx so both the
  # upsert lookup and the create use the same bucket.
  defp put_user_bucket(ctx, "user") do
    case resolve_user_bucket(ctx) do
      {:ok, workspace_id} -> {:ok, Map.put(ctx, :workspace_id, workspace_id)}
      {:error, reason} -> {:error, bucket_error_message(reason)}
    end
  end

  defp put_user_bucket(ctx, _scope), do: {:ok, ctx}
```

Add `resolve_user_bucket: 1, bucket_error_message: 1` to the existing `import Magus.Agents.Tools.Memory.Helpers` list. `create_memory(..., "user", ctx, ...)` keeps reading `Map.get(ctx, :workspace_id)`, which is now the resolved value.

- [ ] **Step 3: Update and extend the tests**

In `set_memory_test.exs`:
(a) The existing `test "defaults scope to user"` becomes `test "defaults scope to local"`: same params, assert `result.scope == nil or result.status == "created"` per the local-create return shape (`{:ok, %{status: "created", name: name, summary: summary}}` for local; check the actual local return map in the module and assert on it), and assert the memory is found via `Memory.get_memory_by_name(conversation.id, "timezone", actor: %Magus.Agents.Support.AiAgent{})` and NOT via `get_user_memory_by_name`.
(b) Add the three regression tests:

```elixir
  describe "user-scope workspace bucketing" do
    test "user-scope write in a workspace conversation lands in that workspace bucket even when ctx omits workspace_id" do
      user = generate(user())
      workspace = generate(workspace(owner_id: user.id))
      {:ok, conv} = Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      context = %{user_id: user.id, conversation_id: conv.id}
      params = %{name: "lang", summary: "Always German", scope: "user"}

      assert {:ok, %{status: "created"}} = SetMemory.run(params, context)

      actor = %Magus.Accounts.User{id: user.id}
      assert {:ok, memory} = Memory.get_user_memory_by_name(workspace.id, "lang", actor: actor)
      assert memory.workspace_id == workspace.id
    end

    test "user-scope write with an invalid conversation_id returns a tool error, not a personal write" do
      user = generate(user())
      context = %{user_id: user.id, conversation_id: Ash.UUID.generate()}
      params = %{name: "x", summary: "y", scope: "user"}

      assert {:ok, %{error: _}} = SetMemory.run(params, context)

      actor = %Magus.Accounts.User{id: user.id}
      assert {:error, _} = Memory.get_user_memory_by_name(nil, "x", actor: actor)
    end

    test "user-scope write with neither conversation_id nor workspace_id key errors" do
      user = generate(user())
      context = %{user_id: user.id}
      params = %{name: "x", summary: "y", scope: "user"}

      assert {:ok, %{error: _}} = SetMemory.run(params, context)
    end
  end
```

Other existing tests that pass `scope: "user"` explicitly and use a context WITHOUT `workspace_id` and WITHOUT `conversation_id` will now error; give them `workspace_id: nil` in the context (explicit personal) or a conversation. Fix each such test minimally.

- [ ] **Step 4: Run** `MIX_ENV=test mix test test/magus/agents/tools/memory/set_memory_test.exs` until green.

- [ ] **Step 5: Also run the sibling tool suites** (they share helpers): `MIX_ENV=test mix test test/magus/agents/tools/memory/` and fix any context fallout the same way.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(memory): set_memory defaults to local and derives the user bucket from the conversation" -- lib/magus/agents/tools/memory/set_memory.ex test/magus/agents/tools/memory/
```

---

### Task 4: ForgetMemory, SearchMemories, UpdateProfile use the resolver

**Files:**
- Modify: `lib/magus/agents/tools/memory/forget_memory.ex`, `lib/magus/agents/tools/memory/search_memories.ex`, `lib/magus/agents/tools/memory/update_profile.ex`
- Test: `test/magus/agents/tools/memory/forget_memory_test.exs`, `test/magus/agents/tools/memory/memory_tools_test.exs`

**Interfaces:**
- Consumes: `resolve_user_bucket/1`, `bucket_error_message/1` (Task 2)
- Produces: all user-scope tool reads/writes resolve the bucket identically.

- [ ] **Step 1: ForgetMemory** - in `run/2`, after `validate_context`, add the same `put_user_bucket(ctx, scope)` helper as Task 3 (copy the two private clauses; they are 8 lines, duplication across two tool modules is acceptable and mirrors existing style). Import the two helper functions.

- [ ] **Step 2: SearchMemories** - same pattern in `run/2` for scopes `"user"` and `"all"` (both read `Map.get(ctx, :workspace_id)` today). `put_user_bucket(ctx, scope)` clauses here match on `"user"` and `"all"`; other scopes pass through. On `{:error, reason}` return `{:ok, %{error: bucket_error_message(reason)}}`.

- [ ] **Step 3: UpdateProfile** - it currently calls `Magus.Memory.workspace_id_for_conversation(ctx.conversation_id)` directly (around line 44). Replace with `resolve_user_bucket(ctx)`; on error return the tool-error map like the other tools.

- [ ] **Step 4: ForgetMemory scope default** - the tool's schema `scope` default is `"user"`; flip it to `"local"` and mirror the Task 3 description language (forget where you saved: local by default). Update `test "defaults scope to user"` accordingly (it becomes "defaults scope to local"; a local memory must exist for the happy path, see the existing "deactivates existing local memory" test for setup).

- [ ] **Step 5: Add one bucket test to forget_memory_test.exs**

```elixir
    test "user-scope forget resolves the workspace bucket from the conversation" do
      user = generate(user())
      workspace = generate(workspace(owner_id: user.id))
      {:ok, conv} = Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      {:ok, _} =
        Memory.create_user_memory(user.id, workspace.id, "ws-fact", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      context = %{user_id: user.id, conversation_id: conv.id}

      assert {:ok, %{status: "forgotten"}} =
               ForgetMemory.run(%{name: "ws-fact", scope: "user"}, context)
    end
```

- [ ] **Step 6: Run all memory tool tests** `MIX_ENV=test mix test test/magus/agents/tools/memory/` until green; fix context-shape fallout minimally (same rule as Task 3).

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(memory): forget/search/update_profile resolve the user bucket from the conversation" -- lib/magus/agents/tools/memory/ test/magus/agents/tools/memory/
```

---

### Task 5: Extraction writes local only

**Files:**
- Modify: `lib/magus/agents/actions/extract_turn_memories.ex`
- Modify: `lib/magus/chat/conversation/changes/extract_turn_memories.ex`
- Test: `test/magus/agents/actions/memory_actions_test.exs`, `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`, plus any test asserting user-scope extraction (grep `apply_user_extraction\|scope.*user` under test/)

**Interfaces:**
- Consumes: nothing new
- Produces: `ExtractTurnMemories.run/2` with NO `allow_global_memories` param and NO scope in the output schema; every extraction applies as a local memory.

- [ ] **Step 1: Shrink the output schema**

In `@output_schema`, delete the `"scope"` property entirely and change the items' `"required"` to `["name", "summary", "content", "reason"]`.

- [ ] **Step 2: Remove the scope decision from the pipeline**

- In the `use Jido.Action` schema: delete the `allow_global_memories` param.
- In `run/2`: delete the `allow_global = Map.get(params, "allow_global_memories", true)` line and pass 4 args to `extract_and_apply(user_id, conversation_id, turns, model)`.
- `extract_and_apply/5` becomes `/4`: drop the `allow_global` param, and `apply_extractions(extractions, conversation_id, user_id)` loses both `workspace_id` and `allow_global` (workspace derivation stays ONLY for loading the user-memory listing for the prompt, see Step 4).
- `apply_extraction/5` collapses to always call `apply_local_extraction(name, content, summary, conversation_id, user_id, update_mode)`. Delete `apply_user_extraction/6`, `create_user_memory/6`, and `find_similar_existing_user/3` (the local dedup path `create_local_memory`/`find_similar_existing` stays; verify the local functions exist with those names before deleting the user ones; only delete functions that become unreferenced, then compile to confirm).
- In `normalize_extraction/1`: delete the `"scope"` key from the normalized map.

- [ ] **Step 3: Rewrite the prompts**

`system_prompt/0` becomes:

```elixir
  defp system_prompt do
    """
    You are a memory extraction assistant. Analyze conversation turns and extract
    information worth persisting for THIS conversation's continuity.

    Focus on:
    - Explicit statements of fact or preference
    - Decisions and commitments
    - Project context the conversation will need later
    - Contradictions of existing memories (extract with update_mode "replace")

    Avoid extracting:
    - Hypotheticals or questions
    - Transient/temporary information
    - Information already captured (unless updating)
    - Facts already listed under known user-level facts

    Be selective - only extract genuinely useful information.
    """
  end
```

`build_prompt/3` becomes (the user-memory listing stays purely as dedup context):

```elixir
  defp build_prompt(local_memories, user_memories, turns) do
    local_text = format_memories(local_memories, "Local")
    user_text = format_memories(user_memories, "User-level")

    """
    ## Existing Memories (this conversation)

    #{local_text}

    ## Known User-Level Facts (do NOT re-extract these)

    #{user_text}

    ## Current Turns

    #{format_turns(turns)}

    ## Instructions

    Extract information worth remembering for this conversation:

    1. **Facts**: Names, dates, preferences explicitly stated
    2. **Decisions**: Choices the user made or confirmed
    3. **Context**: Project details, tasks, goals mentioned

    If information updates an existing memory, use the exact same name.

    Set update_mode when updating an existing memory:
    - "merge" (default): new fields are added to the memory
    - "replace": the new content fully supersedes the old. Use this when the
      new information contradicts or reverses what the memory currently says
      (changed preference, reversed decision, corrected fact).

    If nothing meaningful to extract, return empty extractions list.

    Keep extractions minimal - only persist genuinely useful information.
    """
  end
```

`workspace_id = Magus.Memory.workspace_id_for_conversation(conversation_id)` stays in `extract_and_apply/4` solely to feed `load_user_memories(user_id, workspace_id)` for the prompt.

- [ ] **Step 4: Update the conversation change**

In `lib/magus/chat/conversation/changes/extract_turn_memories.ex`: delete `allow_global = agent_allows_global_writes?(conversation)`, the `allow_global_memories:` key in the `ExtractAction.run` params map, and the now-unused `agent_allows_global_writes?/1` function.

- [ ] **Step 5: Add the never-creates-user-scope regression test**

In `test/magus/agents/actions/memory_actions_test.exs` (it has a mock LLM setup; follow the existing pattern for stubbing `generate_object`), add:

```elixir
    test "extraction never creates user-scope rows even if the LLM emits scope=user" do
      # Mock the LLM to return an extraction carrying a rogue "scope" => "user" key.
      # After running ExtractTurnMemories, assert:
      #   - a local memory with that name exists for the conversation
      #   - Memory.list_user_memories(nil, actor: user_actor) does not contain it
      #   - no Memory row with scope == :user and that name exists at all
    end
```

Write the real test following the file's existing mock conventions (the file stubs the LLM client; mirror the setup of "includes recently updated memories in context" style tests or the extraction tests in the same file). The three assertions in the comment are the required contract; the mock returns `%{"extractions" => [%{"name" => "rogue", "summary" => "s", "content" => %{}, "scope" => "user", "reason" => "r"}]}`.

- [ ] **Step 6: Fix fallout tests.** Grep test/ for `allow_global_memories` and `apply_user_extraction`; update or delete assertions about user-scope extraction (they now assert local landing). `extract_turn_memories_change_test.exs` names suggest no user-scope assertions, but the change no longer passes `allow_global_memories`, so any argument-shape assertions must drop it.

- [ ] **Step 7: Run** `MIX_ENV=test mix test test/magus/agents/actions/memory_actions_test.exs test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs` until green.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(memory): extraction writes local scope only" -- lib/magus/agents/actions/extract_turn_memories.ex lib/magus/chat/conversation/changes/extract_turn_memories.ex test/
```

---

## Phase 2: Simplification

### Task 6: Hard delete: custom destroy action, policy bypass, RPC rename

**Files:**
- Modify: `lib/magus/memory/memory_resource.ex` (actions + policies), `lib/magus/memory/memory.ex` (domain: defines + typescript_rpc), `lib/magus/memory/memory/changes/broadcast_memory_event.ex`, `lib/magus/agents/tools/memory/forget_memory.ex`
- Test: `test/magus/memory/memory_test.exs`, `test/magus/memory/memory_user_rpc_policy_test.exs`, `test/magus/agents/tools/memory/forget_memory_test.exs`

**Interfaces:**
- Consumes: existing `update :deactivate` (removed here)
- Produces: `Magus.Memory.destroy_memory(memory, actor: ...)` (destroy action `:destroy` with broadcast); RPC `destroy_user_memory` -> `:destroy`; AI-agent policy bypass includes `:destroy`. Retraction enqueue is Task 7 (this task only hard-deletes and broadcasts).

- [ ] **Step 1: Replace deactivate with a custom destroy in `memory_resource.ex`**

Delete the whole `update :deactivate do ... end` block. Ensure the actions block declares a custom destroy (if `defaults` includes `:destroy`, remove it from defaults and add):

```elixir
    destroy :destroy do
      primary? true
      require_atomic? false

      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent
    end
```

- [ ] **Step 2: BroadcastMemoryEvent handles destroy**

Open `lib/magus/memory/memory/changes/broadcast_memory_event.ex`. It maps action names to event types (deactivate -> deleted). Add/adjust so action `:destroy` broadcasts the `memory_deleted` signal. Destroy changes run their after_action with the destroyed record struct; keep the existing Signals call shape.

- [ ] **Step 3: Policy bypass**

In the policies block of `memory_resource.ex` change:

```elixir
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end
```

The existing creator-only destroy policy for users stays (verify a `policy action_type(:destroy)` or equivalent exists; the resource has "Update/Destroy Policies: Creator only" per the audit).

- [ ] **Step 4: Domain updates in `memory.ex`**

- Replace `define :deactivate_memory, action: :deactivate` with `define :destroy_memory, action: :destroy`.
- In `typescript_rpc`, replace `rpc_action :deactivate_user_memory, :deactivate` with `rpc_action :destroy_user_memory, :destroy`.

- [ ] **Step 5: Update callers**

Grep `deactivate_memory` across lib/ and replace with `destroy_memory` (ForgetMemory's `Memory.deactivate_memory(memory, actor: ai_actor())` becomes `Memory.destroy_memory(memory, actor: ai_actor())`; note `ConsolidateMemories.decay_stale_memories` also calls it, but that whole function is deleted in Task 9, so for THIS task just switch the call there too so the code compiles).

- [ ] **Step 6: Update tests**

- `memory_test.exs`: `test "soft deletes by setting is_active to false"` becomes `test "destroy hard-deletes the row"`: destroy then `assert {:error, _} = Memory.get_memory(memory.id, actor: user)`. Same for "deactivated memory not returned by for_conversation" (destroyed memory not returned).
- `memory_user_rpc_policy_test.exs`: the deactivate test becomes destroy: `Ash.Changeset.for_destroy(mem, :destroy, %{}, actor: other)` must error; with `actor: user` must succeed (`Ash.destroy`).
- `forget_memory_test.exs`: add the policy-bypass pin:

```elixir
    test "ForgetMemory as ai_actor hard-deletes the memory" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(conv.id, user.id, "gone", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      context = %{user_id: user.id, conversation_id: conv.id}
      assert {:ok, %{status: "forgotten"}} = ForgetMemory.run(%{name: "gone", scope: "local"}, context)
      assert {:error, _} = Magus.Memory.get_memory(memory.id, authorize?: false)
    end
```

- Add the re-create regression:

```elixir
    test "hard-delete then re-create with the same name succeeds" do
      # create local memory "again", destroy it, create local memory "again" in the
      # same conversation; the second create must succeed (unique index no longer
      # blocked by a soft-deleted row).
    end
```

(Write it fully following the surrounding test style.)

- [ ] **Step 7: Run** `MIX_ENV=test mix test test/magus/memory/ test/magus/agents/tools/memory/` until green. Note: `is_active` still exists (filters still reference it) and destroy removes rows, so `is_active == true` filters remain harmless until Task 11.

- [ ] **Step 8: Commit**

```bash
git commit -m "feat(memory): hard delete replaces deactivate (destroy action, AI bypass, RPC rename)" -- lib/magus/memory/ lib/magus/agents/ test/magus/
```

---

### Task 7: Super Brain retraction on destroy

**Files:**
- Create: `lib/magus/super_brain/workers/retract_resource.ex`
- Modify: `lib/magus/super_brain/workers/extract_memory.ex` (make `route/1` public), `lib/magus/memory/memory_resource.ex` (enqueue on destroy)
- Test: `test/magus/super_brain/workers/retract_resource_test.exs` (new)

**Interfaces:**
- Consumes: `Magus.SuperBrain.Episode` (Postgres resource; `Claim` has `reference :episode, on_delete: :delete` so claims cascade), `Magus.Graph.query/3`, `ExtractMemory.route/1` returning `{:ok, graph_name, extra_props} | {:error, term}`
- Produces: `Magus.SuperBrain.Workers.RetractResource` Oban worker (queue `:super_brain_extraction`), args `%{"resource_type" => "memory", "resource_id" => id, "graph_name" => name}`; enqueued from the memory `:destroy` after_action for scopes user/agent when Super Brain is enabled.

- [ ] **Step 1: Make routing public**

In `extract_memory.ex`, change `defp route(` to `def route(` and add above it:

```elixir
  @doc """
  Public: RetractResource reuses the same routing at destroy time, when the
  row is already gone from Postgres but the struct is still in memory.
  """
```

- [ ] **Step 2: Write the worker**

```elixir
defmodule Magus.SuperBrain.Workers.RetractResource do
  @moduledoc """
  Removes a hard-deleted resource's derived Super Brain data.

  Postgres is the definitive cleanup: deleting the Episode rows for the
  resource cascades to Claims (FK on_delete: :delete), which removes the
  facts from claims-backed retrieval. The L1 graph episode node is deleted
  best-effort; orphaned entity nodes and stale L2 edges are accepted and
  healed by the next replay or migration sweep (the graph is a derived,
  disposable index).

  Generic over resource_type so future hard-delete paths (drafts, files)
  can reuse it.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  require Ecto.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"resource_id" => resource_id} = args}) do
    resource_type = Map.get(args, "resource_type", "memory")
    graph_name = Map.get(args, "graph_name")

    delete_episodes(resource_type, resource_id)
    delete_graph_episode(graph_name, resource_id)

    :ok
  end

  defp delete_episodes(resource_type, resource_id) do
    {count, _} =
      Magus.SuperBrain.Episode
      |> Ecto.Query.from()
      |> Ecto.Query.where(
        [e],
        e.resource_type == ^resource_type and e.resource_id == ^resource_id
      )
      |> Magus.Repo.delete_all()

    Logger.debug("RetractResource: deleted #{count} episode rows for #{resource_type}/#{resource_id}")
  end

  defp delete_graph_episode(nil, _resource_id), do: :ok

  defp delete_graph_episode(graph_name, resource_id) do
    case Magus.Graph.query(
           graph_name,
           "MATCH (e:Episode {resource_id: $resource_id}) DETACH DELETE e",
           %{resource_id: to_string(resource_id)}
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RetractResource: graph episode delete failed for #{graph_name}: #{inspect(reason)} - stale graph data heals on rebuild"
        )

        :ok
    end
  end
end
```

Caveats to verify while implementing: (a) `Episode.resource_type` is an atom column stored as text; if the Ecto where on a string fails the type cast, compare with `type(^resource_type, :string)` or query with the atom - check `Magus.SuperBrain.Episode` attribute types and mirror how `cleanup.ex` filters. (b) `Magus.SuperBrain.Episode` is an Ash resource usable as an Ecto schema (`cleanup.ex` does exactly this with `Repo.delete_all`). (c) Confirm the Episode graph node label and property (`Episode` / `resource_id`) match what `ExtractBase` writes; grep `Episode` in `lib/magus/super_brain/extraction.ex` or `extract_base.ex` and adjust the Cypher if the property is named differently.

- [ ] **Step 3: Enqueue from destroy**

In `memory_resource.ex`, extend the destroy action:

```elixir
    destroy :destroy do
      primary? true
      require_atomic? false

      change Magus.Memory.Memory.Changes.BroadcastMemoryEvent

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, memory ->
          enqueue_super_brain_retraction(memory)
          {:ok, memory}
        end)
      end
    end
```

and add next to `enqueue_super_brain_extraction/1`:

```elixir
  @doc false
  # Local memories are never extracted into a graph, so there is nothing to
  # retract for them.
  def enqueue_super_brain_retraction(%{scope: :local}), do: :ok

  def enqueue_super_brain_retraction(%{id: id, scope: scope} = memory)
      when scope in [:user, :agent] do
    if Magus.SuperBrain.enabled?() do
      graph_name =
        case Magus.SuperBrain.Workers.ExtractMemory.route(memory) do
          {:ok, graph_name, _extra} -> graph_name
          _ -> nil
        end

      %{"resource_type" => "memory", "resource_id" => id, "graph_name" => graph_name}
      |> Magus.SuperBrain.Workers.RetractResource.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  def enqueue_super_brain_retraction(_), do: :ok
```

Check whether `route/1` needs relationships loaded (e.g. custom_agent for agent scope); if the destroyed struct lacks them, `Ash.load` the struct fields route needs BEFORE destroy is fine because the after_action receives the pre-destroy struct. If route errors, we enqueue with `graph_name => nil` (Postgres cleanup still runs).

- [ ] **Step 4: Tests**

```elixir
defmodule Magus.SuperBrain.Workers.RetractResourceTest do
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generator

  test "destroying a user-scope memory enqueues RetractResource" do
    user = generate(user())

    {:ok, memory} =
      Magus.Memory.create_user_memory(user.id, nil, "fact", %{content: %{}, summary: "s"},
        actor: %Magus.Agents.Support.AiAgent{}
      )

    {:ok, _} = Magus.Memory.destroy_memory(memory, actor: user)

    assert_enqueued(
      worker: Magus.SuperBrain.Workers.RetractResource,
      args: %{"resource_type" => "memory", "resource_id" => memory.id}
    )
  end

  test "perform deletes the matching Episode rows" do
    # Insert an Episode row for a fake memory id via the Episode resource's
    # create action (see test/magus/super_brain/ for the existing pattern),
    # run RetractResource.perform with matching args and graph_name nil,
    # assert the Episode row is gone.
  end
end
```

Write the second test fully using the Episode-creation pattern found in existing super_brain tests (grep `Episode` under test/magus/super_brain/). Gate the enqueue assertion on `Magus.SuperBrain.enabled?()` in test env; if it is disabled by default in test config, set the relevant config in the test setup (see how existing extract-worker tests enable it).

- [ ] **Step 5: Run** the new test file + `test/magus/memory/` green.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(super-brain): RetractResource worker; memory destroy retracts episodes/claims" -- lib/magus/super_brain/ lib/magus/memory/ test/
```

---

### Task 8: Enforce the per-conversation cap at extraction time

**Files:**
- Modify: `lib/magus/agents/actions/extract_turn_memories.ex`
- Test: `test/magus/agents/actions/memory_actions_test.exs`

**Interfaces:**
- Consumes: `Magus.Config.max_memories_per_conversation/0` (exists, currently dead), `Magus.Memory.destroy_memory/2` (Task 6), `Magus.Memory.list_memories_for_conversation/2`
- Produces: after applying extractions, the conversation's local memories never exceed the cap; oldest-by-updated_at evicted first.

- [ ] **Step 1: Implement eviction**

In `extract_and_apply/4`, after `apply_extractions(...)` returns `{applied, skipped}`, add `evicted = enforce_conversation_cap(conversation_id)` and include `memories_evicted: evicted` in the `{:ok, %{...}}` result map. Implementation:

```elixir
  # Deterministic growth bound: the per-conversation cap replaces time-based
  # decay. Oldest-by-update evicted first, through the real destroy action so
  # PubSub and Super Brain retraction fire.
  defp enforce_conversation_cap(conversation_id) do
    cap = Magus.Config.max_memories_per_conversation()

    case Memory.list_memories_for_conversation(conversation_id, actor: @actor) do
      {:ok, memories} when length(memories) > cap ->
        memories
        |> Enum.sort_by(& &1.updated_at, {:asc, DateTime})
        |> Enum.take(length(memories) - cap)
        |> Enum.reduce(0, fn memory, count ->
          case Memory.destroy_memory(memory, actor: @actor) do
            {:ok, _} -> count + 1
            {:error, _} -> count
          end
        end)

      _ ->
        0
    end
  end
```

- [ ] **Step 2: Test** (in memory_actions_test.exs, following its LLM-mock pattern):

```elixir
    test "extraction evicts the least recently updated local memories over the cap" do
      # setup: conversation with (cap) existing local memories created oldest-first
      #   (Magus.Config.max_memories_per_conversation() returns 20 by default; to
      #   keep the test fast, create cap memories with distinct names).
      # mock LLM: returns 2 new extractions
      # run ExtractTurnMemories
      # assert: list_memories_for_conversation returns exactly cap rows,
      #   the 2 oldest original names are gone, the 2 new names exist.
    end
```

Write it fully; if creating 20 rows is slow, override the config in the test with `Application.put_env(:magus, Magus.Memory, Keyword.put(Application.get_env(:magus, Magus.Memory), :max_memories_per_conversation, 5))` in setup and restore in `on_exit` (check how `Magus.Config.max_memories_per_conversation/0` reads config: `get(Magus.Memory, :max_memories_per_conversation, 20)`; app-env override works; note config is a keyword list).

- [ ] **Step 3: Run + commit**

```bash
git commit -m "feat(memory): enforce max_memories_per_conversation with evict-oldest at extraction" -- lib/magus/agents/actions/extract_turn_memories.ex test/magus/agents/actions/memory_actions_test.exs
```

---

### Task 9: Remove promotion, merge, and decay; consolidation = distill only

**Files:**
- Delete: `lib/magus/agents/actions/promote_memory_candidates.ex`, `lib/magus/agents/actions/merge_memories.ex`
- Modify: `lib/magus/agents/actions/consolidate_memories.ex`, `lib/magus/memory/memory_resource.ex` (remove `:promote_to_user`), `lib/magus/memory/memory.ex` (remove `define :promote_memory_to_user`)
- Test: `test/magus/agents/actions/consolidate_memories_profile_test.exs` (keep green), delete/update any promote/merge tests (grep `PromoteMemoryCandidates\|MergeMemories\|promote_to_user\|promote_memory_to_user` under test/)

- [ ] **Step 1:** Delete the two action modules and their test files (grep test/ for their names first; delete those test files).

- [ ] **Step 2:** In `consolidate_memories.ex`:
- Delete `decay_stale_memories/2`, the promotion step, the merge step, and the params `stale_threshold_days`, `skip_promotion`, `skip_merge` (keep `workspace_filter`).
- `do_consolidation/2` keeps: bucket enumeration (`workspace_buckets_for/1`), the `profile_enabled?` gate, `distill_profiles(user_id, buckets)`.
- The result map becomes `%{profiles_distilled: n, user_id: user_id, completed_at: DateTime.utc_now()}`.
- Remove the aliases for the deleted modules.

- [ ] **Step 3:** In `memory_resource.ex`, delete the whole `update :promote_to_user do ... end` block. In `memory.ex`, delete `define :promote_memory_to_user, action: :promote_to_user` and the `# Scope management` comment.

- [ ] **Step 4:** Grep `lib/` and `test/` for `promote\|MergeMemories\|decay_stale\|stale_threshold_days\|skip_promotion\|skip_merge`; fix every reference (the mix task `lib/mix/tasks/magus.consolidate_memories.ex` likely passes these params; simplify it to user_id + workspace_filter).

- [ ] **Step 5: Pin the no-ambient-deletion invariant** (spec requirement). Add to `test/magus/agents/actions/consolidate_memories_profile_test.exs` (or a sibling consolidation test file if one fits better):

```elixir
    test "consolidation never deletes user-scope rows, even ancient ones" do
      user = generate(user())

      {:ok, memory} =
        Magus.Memory.create_user_memory(user.id, nil, "keep-me", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # Backdate far past the old 90-day decay window.
      {:ok, uuid} = Ecto.UUID.dump(memory.id)

      Magus.Repo.query!(
        "UPDATE memories SET updated_at = now() - interval '200 days' WHERE id = $1",
        [uuid]
      )

      {:ok, _} = Magus.Agents.Actions.ConsolidateMemories.run(%{user_id: user.id}, %{})

      assert {:ok, _} = Magus.Memory.get_memory(memory.id, authorize?: false)
    end
```

- [ ] **Step 6:** Run `MIX_ENV=test mix test test/magus/agents/actions/ test/magus/memory/` green; `MIX_ENV=test mix compile --warnings-as-errors` clean.

- [ ] **Step 7: Commit**

```bash
git commit -m "refactor(memory): consolidation is distill-only; remove promotion, merge, decay" -- lib/ test/
```

---

### Task 10: Distiller reads recent local memories per bucket

**Files:**
- Modify: `lib/magus/agents/actions/distill_user_profile.ex`
- Test: `test/magus/agents/actions/distill_user_profile_test.exs`

**Interfaces:**
- Consumes: `Magus.Memory.Memory` (direct Ash query), profile `last_distilled_at`
- Produces: distiller input = current document + pending notes + up to 100 local memories updated since `last_distilled_at` in the bucket (personal bucket = nil-workspace locals). User-bucket memories are NO LONGER distiller input (they are injected directly every turn).

- [ ] **Step 1: Failing test** (mirror the existing mock-LLM pattern in the file; the first test shows how the LLM stub captures the prompt):

```elixir
  test "distills from recent local memories in the matching bucket" do
    # setup: user; one LOCAL memory in a personal conversation named "Lisbon move"
    #   (summary "User moved to Lisbon"), one USER-scope memory named "Old fact".
    # stub LLM to capture the prompt and return a document.
    # run DistillUserProfile with workspace_id: nil.
    # assert the captured prompt CONTAINS "Lisbon move" and DOES NOT contain "Old fact".
    # assert prompt section header "Recent Conversation Memories" is present.
  end
```

Write it fully following the file's existing stub/capture conventions.

- [ ] **Step 2: Implement**

Replace `load_memories/2`:

```elixir
  # Local memories are the distiller's raw feed: recent rows from the bucket's
  # conversations since the last distillation (capped). User-bucket rows are
  # explicit writes that are injected directly each turn and are not part of
  # the distiller input.
  defp load_memories(user_id, workspace_id, since) do
    require Ash.Query

    query =
      Magus.Memory.Memory
      |> Ash.Query.filter(user_id == ^user_id and scope == :local)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@max_memories)

    query =
      if is_nil(workspace_id) do
        Ash.Query.filter(query, is_nil(workspace_id))
      else
        Ash.Query.filter(query, workspace_id == ^workspace_id)
      end

    query =
      if since do
        Ash.Query.filter(query, updated_at > ^since)
      else
        query
      end

    case Ash.read(query, actor: @actor) do
      {:ok, memories} -> memories
      _ -> []
    end
  end
```

Bump `@max_memories` from 50 to 100 (spec). In `run/2` call it as `load_memories(user_id, workspace_id, profile.last_distilled_at)`. In `build_prompt/2` rename the section `## Stored User Memories (most recent first)` to `## Recent Conversation Memories (most recent first)`. Note the Ash filter pin: filtering on `is_nil(workspace_id)` inside `Ash.Query.filter` with the `query` variable requires `require Ash.Query` (already at top of the new function).

- [ ] **Step 3:** Existing tests in the file stub user-bucket memories via `list_user_memories`; update their setups to create LOCAL memories instead (the shape of assertions stays). Run the file green.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(memory): distiller reads recent bucket-scoped local memories" -- lib/magus/agents/actions/distill_user_profile.ex test/magus/agents/actions/distill_user_profile_test.exs
```

---

### Task 11: Remove the association layer

**Files:**
- Delete: `lib/magus/memory/memory_association.ex`, `lib/magus/memory/memory_association/` (validations dir), `test/magus/memory/memory_association_test.exs`, `test/magus/memory/memory_association_workspace_test.exs`, `test/magus/memory/memory_association_decay_test.exs`
- Modify: `lib/magus/agents/actions/build_memory_context.ex`, `lib/magus/memory/memory.ex` (domain resource entry + defines), `lib/magus/memory/memory_resource.ex` (relationships `associations_as_a/b`)
- Test: `test/magus/agents/actions/build_memory_context_test.exs`, `build_memory_context_format_test.exs`, `memory_actions_test.exs`

- [ ] **Step 1:** In `build_memory_context.ex`: delete the Layer 3 block (`all_retrieved_ids` / `expand_associations` / `associated`), `reinforce_co_retrieved(all_memory_ids)` and both `reinforce_co_retrieved` clauses, `expand_associations/1`, and the module attributes `@max_reinforcement_pairs`, `@min_effective_assoc_weight`, `@max_associated_results` (grep the file for each before deleting; names may differ slightly). `format_context(important, semantic ++ associated, ...)` becomes `format_context(important, semantic, ...)`.

- [ ] **Step 2:** In `memory.ex` domain: remove the `Magus.Memory.MemoryAssociation` resource block (defines `create_memory_association`, `reinforce_association`, `get_associations_for_memory`, `get_association_between`). In `memory_resource.ex`: remove the `associations_as_a` / `associations_as_b` relationships.

- [ ] **Step 3:** Delete the resource + validation files and the three test files.

- [ ] **Step 4:** Grep `lib/ test/` for `MemoryAssociation\|association` under memory/agents paths; fix stragglers (e.g. `memory_actions_test.exs` may assert associated-layer behavior).

- [ ] **Step 5:** Run `MIX_ENV=test mix test test/magus/agents/actions/ test/magus/memory/`; `MIX_ENV=test mix compile --warnings-as-errors`.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(memory): remove Hebbian association layer" -- lib/ test/
```

---

### Task 12: Remove MemoryVersion, MemorySource, touch machinery, and dead columns from code

**Files:**
- Delete: `lib/magus/memory/memory_version.ex`, `lib/magus/memory/memory_source.ex`, `lib/magus/memory/memory/changes/create_version.ex`, `test/magus/memory/memory_source_test.exs`
- Modify: `lib/magus/memory/memory_resource.ex`, `lib/magus/memory/memory.ex`, `lib/magus/agents/actions/build_memory_context.ex`, `lib/magus/agents/tools/memory/search_memories.ex`, `lib/magus/agents/tools/memory/set_memory.ex`, `lib/magus/agents/custom_agent.ex`, `lib/magus/accounts/data_export.ex`
- Test: `test/magus/memory/memory_test.exs`, `test/magus/agents/` fallout

**Keep:** `UserProfileVersion` and `lib/magus/memory/user_profile/changes/create_version.ex` stay (third-round decision).

- [ ] **Step 1: memory_resource.ex**
- Attributes: delete `is_active`, `confidence`, `structured_data`, `last_accessed_at`.
- Actions: remove `Magus.Memory.Memory.Changes.CreateVersion` change lines from `:create`, `:create_user`, `:create_agent`, `:set`, `:clear`; remove `:confidence, :structured_data` from every `accept`; remove all `is_active == true` clauses from read-action filters; identities/`unique_*` definitions drop their `where: [is_active: true]`-style predicates (keep the scope predicates; the exact DSL is `identity ... where expr(...)` or custom index statements - mirror what is there, minus is_active).
- Relationships: delete `versions` and `sources` has_many.

- [ ] **Step 2: memory.ex domain**
- Remove the `MemoryVersion` and `MemorySource` resource blocks and defines (`create_memory_version`, source defines).
- Delete `touch_accessed/1` (both clauses).

- [ ] **Step 3: Callers**
- `build_memory_context.ex`: delete `touch_accessed_memories/1` and its call (plus the comment block about bumping last_accessed_at).
- `search_memories.ex`: delete `touch_memory_ids/1` and its 3 call sites; remove `confidence:` from `format_result/2`.
- `set_memory.ex`: drop `confidence` and `structured_data` params from the schema, `build_extra_attrs/3` becomes `build_extra_attrs(kind)`, drop the two `get_param` lines.
- `custom_agent.ex`: in `action :update_agent_memory` remove the `confidence` argument and the `confidence:` attr (and `clamp_confidence/1` if now unused); `memory_map/1` drops `confidence`.
- `data_export.ex` `memories/1`: remove the `Ash.Query.filter(... is_active == true)` clause and the whole `is_active` concept, the `[:versions, :sources]` load, and the `structured_data`, `confidence`, `versions:`, `sources:` keys.

- [ ] **Step 4: Tests.** Delete `memory_source_test.exs`. In `memory_test.exs` delete/rewrite version tests ("creates initial version on create", "creates new version on update"), confidence/kind tests keep only kind. Grep test/ for `is_active\|confidence\|structured_data\|versions\|sources` under memory paths and fix. `MemoryVersion`-based changed_by assertions go away.

- [ ] **Step 5:** Full backend check: `MIX_ENV=test mix compile --warnings-as-errors` then `MIX_ENV=test mix test test/magus/memory/ test/magus/agents/ test/magus/accounts/`.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor(memory): remove versions, sources, confidence, structured_data, is_active, touch machinery from code" -- lib/ test/
```

---

### Task 13: Migration wave

**Files:**
- Generate: `priv/repo/migrations/*_memory_v2_simplification.exs` (via codegen) + manual pre-clean edit
- Modify: `priv/resource_snapshots/` (codegen-managed)

- [ ] **Step 1:** `mix ash.codegen memory_v2_simplification`
Expected: a migration dropping `memory_versions`, `memory_sources`, `memory_associations` tables; dropping `is_active`, `confidence`, `structured_data`, `last_accessed_at` columns; rebuilding the three unique indexes without the is_active predicate; dropping the `[conversation_id, last_accessed_at]` index. Review the generated file; if codegen misses an index change, add it manually.

- [ ] **Step 2:** Edit the generated migration: as the FIRST statement of `up`, before any column/index drops:

```elixir
    execute("DELETE FROM memories WHERE is_active = false")
```

(Old inactive duplicates would otherwise violate the rebuilt scope-only unique indexes.)

- [ ] **Step 3:** Run against the test partition: `MIX_TEST_PARTITION=_memv2 MIX_ENV=test mix ash.migrate` (or `mix ecto.migrate` per project convention). Then the full non-e2e suite: `MIX_TEST_PARTITION=_memv2 MIX_ENV=test mix test` - target 0 failures beyond the known pre-existing shared-DB failures documented in Global Constraints.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(memory): memory v2 migration wave (drop dead tables/columns, rebuild identities)" -- priv/repo/migrations/ priv/resource_snapshots/
```

---

### Task 14: SPA + RPC client updates

**Files:**
- Regenerate: `frontend/src/lib/ash/ash_rpc.ts` (+ `ash_types.ts`) via `mix ash_typescript.codegen` (verify exact task name with `mix help --search typescript`; the previous memory-settings plan used this task)
- Modify: `frontend/src/lib/ash/api.ts`, `frontend/src/routes/settings/memory/+page.svelte`, plus whatever calls `updateAgentMemory` with confidence (grep `updateAgentMemory\|AgentMemory` under frontend/src)

- [ ] **Step 1:** Regenerate the RPC client. `deactivateUserMemory` disappears; `destroyUserMemory` appears.

- [ ] **Step 2:** `api.ts`:
- `UserMemory` type and `USER_MEMORY_FIELDS`: remove `confidence`.
- Replace the wrapper:

```typescript
export async function destroyUserMemory(memoryId: string): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.destroyUserMemory({ identity: memoryId, fields: ['id'], ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? memoryId) } };
}
```

(Check the generated signature: destroy RPC actions may return no fields; if `fields: ['id']` fails svelte-check, use the generated input type's minimal shape and return `{ id: memoryId }`.)
- `AgentMemory` type: remove `confidence`; `toAgentMemory` drops the confidence line; `updateAgentMemory` input loses `confidence`.

- [ ] **Step 3:** `settings/memory/+page.svelte`:
- Swap `deactivateUserMemory` import/call for `destroyUserMemory`.
- Delete the Confidence `<dt>/<dd>` pair from the detail block.
- Delete copy: `description: `"${m.name}" will be removed from your memory.`` becomes `description: `"${m.name}" will be permanently deleted.``.

- [ ] **Step 4:** Fix the agent-memory edit UI (wherever `updateAgentMemory` is called with confidence: remove the field from the form and the call).

- [ ] **Step 5:** Gates: `cd frontend && npm run check && npm run test:unit && npm run format:check`. All green.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(spa): memory v2 client updates (hard delete, drop confidence)" -- frontend/src
```

(The regenerated `ash_rpc.ts`/`ash_types.ts` live under `frontend/src/lib/ash/` and are covered by the path above.)

---

### Task 15: Final sweep, gates, and evals

**Files:** none new; verification only (plus small fixes it uncovers)

- [ ] **Step 1: Removal grep.** Each of these must return NOTHING under `lib/` and `frontend/src/` (test references only where a test pins absence):
`is_active`, `confidence` (memory contexts only; other domains may legitimately use the word - scope the grep to memory/agents/settings files), `structured_data`, `deactivate_memory`, `deactivateUserMemory`, `last_accessed_at`, `touch_accessed`, `promote_memory_to_user`, `PromoteMemoryCandidates`, `MergeMemories`, `MemoryVersion` (NOT UserProfileVersion), `MemorySource`, `MemoryAssociation`, `allow_global_memories`.

- [ ] **Step 2:** `MIX_ENV=test mix compile --warnings-as-errors` (CI gate), then `mix precommit` (or its component steps if the alias wedges on the dev server: format, compile warnings-as-errors, full non-e2e test).

- [ ] **Step 3:** SPA gates again if anything changed since Task 14.

- [ ] **Step 4 (controller step, needs .env + network): LongMemEval regression tripwire.** Follow `docs/superpowers/plans/2026-07-04-memory-eval-baselines.md`: run the LongMemEval-S benchmark at limit 18 via `Magus.Eval.Runner` with `Magus.Eval.Benchmarks.LongMemEval` against the eval partition. Compare against the 3/18 hardened baseline in `eval/results/longmemeval.jsonl`. A drop to <= 1/18 blocks merge; 2-4/18 is within noise, note it. This step is run by the controller (needs OPENROUTER_API_KEY and the dataset download), not by an implementer subagent.

- [ ] **Step 5:** Update `docs/system/05-memory-system.md` to match v2 (scopes unchanged; extraction local-only; distiller sole curator; hard deletes; cap instead of decay; no associations/versions/sources). Rewrite the affected sections directly from the spec's design sections 1-3.

- [ ] **Step 6: Commit**

```bash
git commit -m "docs(memory): update system doc for memory v2" -- docs/system/05-memory-system.md
```

---

## Self-review notes (plan author)

- Task ordering keeps every commit compiling: destroy (6) lands before its callers change (7, 8); code removals (9-12) precede the migration (13) so codegen sees final resources; SPA (14) follows the RPC rename (6) and migration (13).
- `is_active` filters remain between Tasks 6 and 12; that is safe (rows are hard-deleted, the filter matches everything remaining).
- Phase 1 (Tasks 1-5) is shippable alone per the spec; the promotion pipeline still runs until Task 9 removes it.
- The distiller change (Task 10) lands before column removals (Task 12) touch shared files; both edit different functions.
