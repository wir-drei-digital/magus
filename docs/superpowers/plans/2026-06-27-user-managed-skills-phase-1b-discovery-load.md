# User-Managed Skills — Phase 1B: Discovery + load_skill Dispatch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user skills discoverable and loadable: the agent sees a per-conversation merged list of built-in plus accessible user skills (each with a stable ref) in its system prompt, and `load_skill` resolves a ref to load a user skill's instructions and requested tools, exactly as it already does for built-in skills.

**Architecture:** A new `Magus.Skills.Discovery` module merges built-in registry skills with the user/workspace skills the actor can access into one list of views, each carrying a stable `ref`. `system_prompts.ex` builds the "## Available Skills" section from those views (replacing the built-in-only section). `load_skill` gains ref-aware dispatch: `user:<id>` loads a DB skill (access-checked), persisting its `body` to `conversation.skill_context` and its `requested_tools` to `conversation.skill_tools` — reusing the exact persistence and mid-turn `__new_tools__` path built-in skills already use. No schema change.

**Tech Stack:** Elixir, Ash 3.x, Jido actions, ExUnit (`Magus.ResourceCase` / `ExUnit.Case`).

## Plan sequence (context)

This is plan **1B of the Phase 1 backend** and builds directly on 1A (the `Magus.Skills.Skill` resource, domain, `list_skills`/`get_skill` interfaces, and policies — all merged on branch `worktree-user-managed-skills-1a`). It produces working, testable software: the agent can discover and load **prompt-only** user skills end to end.

**Out of scope (later plans):** bundle storage, import pipeline, sandbox materialization, first-run approval, secret sourcing, the `create_skill` tool (all **1C**); the SPA UI; Phases 2/3. A user skill that has `has_executable_bundle: true` will still load its **body** here, but nothing materializes or runs its scripts until 1C. Do not add materialization/approval in this plan.

## Resolved decision (was the open 1B question)

Skills are loaded by **`skill_ref`, not by name.** Discovery assigns each skill a unique ref (`builtin:<name>` for registry skills, `user:<id>` for DB skills) and `load_skill` resolves the ref. Therefore **no `(user_id, name)` uniqueness constraint is added** — name collisions across built-in/personal/workspace sources are disambiguated by ref. `load_skill` still accepts a bare built-in name as a backward-compatible fallback.

## Global Constraints

- Call resources through domain code interfaces (`Magus.Skills.list_skills/1`, `Magus.Skills.get_skill/2`), never `Ash.read/4` directly. Always pass a real `actor:`.
- The actor for both discovery and user-skill loading is the conversation owner: `context[:user]` (a `%Magus.Accounts.User{}`, already present in the tool context) in tools, and the `user` argument already threaded through `system_prompts` `compose`.
- Reuse the existing persistence path: `conversation.skill_context` (instructions, appended) and `conversation.skill_tools` (tool-name strings, merged), via `Magus.Chat.set_conversation_skill/3`. User-skill `requested_tools` are existing Magus tool names resolved by `ToolBuilder.resolve_skill_tools/1` (no new tool modules).
- No schema/migration changes in this plan.
- Tests: resource-touching tests use `use Magus.ResourceCase, async: true`; pure-config/unit tests use `use ExUnit.Case, async: true`. Test command in this worktree: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`.
- Before committing new Elixir, run `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`.
- No em dashes in prose or comments.

---

### Task 1: `Magus.Skills.Discovery` — per-actor merged skill list

**Files:**
- Create: `lib/magus/skills/discovery.ex`
- Test: `test/magus/skills/discovery_test.exs`

**Interfaces:**
- Produces: `Magus.Skills.Discovery.list_for_actor(actor_or_nil)` → `[view]` where
  `view = %{ref: String.t(), name: String.t(), description: String.t(), source: :builtin | :user, has_executable_bundle: boolean()}`.
  Built-in ref is `"builtin:<name>"`; user ref is `"user:<id>"`. Built-in views always returned; user views only when `actor` is non-nil.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/discovery_test.exs`:

```elixir
defmodule Magus.Skills.DiscoveryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills
  alias Magus.Skills.Discovery

  test "includes built-in skills with builtin: refs even for a nil actor" do
    views = Discovery.list_for_actor(nil)
    assert Enum.all?(views, &(&1.source == :builtin))
    assert Enum.all?(views, &String.starts_with?(&1.ref, "builtin:"))
    # The repo ships built-in skills under priv/skills, so the list is non-empty.
    assert views != []
  end

  test "includes the actor's own user skills with user: refs, isolated per actor" do
    owner = generate(user())
    stranger = generate(user())
    {:ok, skill} = Skills.create_skill(%{name: "mine-disc", description: "d"}, actor: owner)

    owner_refs = Discovery.list_for_actor(owner) |> Enum.map(& &1.ref)
    assert ("user:" <> skill.id) in owner_refs

    stranger_refs = Discovery.list_for_actor(stranger) |> Enum.map(& &1.ref)
    refute ("user:" <> skill.id) in stranger_refs
  end

  test "refs are unique across the merged list" do
    owner = generate(user())
    {:ok, _} = Skills.create_skill(%{name: "uniq-disc", description: "d"}, actor: owner)
    refs = Discovery.list_for_actor(owner) |> Enum.map(& &1.ref)
    assert length(refs) == length(Enum.uniq(refs))
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/discovery_test.exs`
Expected: FAIL (`Magus.Skills.Discovery` undefined).

- [ ] **Step 3: Create the Discovery module**

Create `lib/magus/skills/discovery.ex`:

```elixir
defmodule Magus.Skills.Discovery do
  @moduledoc """
  Per-actor skill discovery: merges built-in registry skills with the
  user/workspace skills an actor can access into one list of skill views,
  each carrying a stable `ref` that `load_skill` resolves unambiguously.

  Refs: built-in -> "builtin:<name>", user skill -> "user:<id>".
  """

  alias Magus.Agents.Skills.Registry

  @type view :: %{
          ref: String.t(),
          name: String.t(),
          description: String.t(),
          source: :builtin | :user,
          has_executable_bundle: boolean()
        }

  @doc """
  List all skills visible to `actor` (built-in plus accessible user skills),
  as views with stable refs. Built-in views are always returned; user views
  require a non-nil `%Magus.Accounts.User{}` actor (access governed by policies).
  """
  @spec list_for_actor(struct() | nil) :: [view()]
  def list_for_actor(actor) do
    builtin_views() ++ user_views(actor)
  end

  defp builtin_views do
    Registry.list_skills()
    |> Enum.map(fn s ->
      %{
        ref: "builtin:" <> s.name,
        name: s.name,
        description: s.description || "",
        source: :builtin,
        has_executable_bundle: false
      }
    end)
  end

  defp user_views(nil), do: []

  defp user_views(actor) do
    case Magus.Skills.list_skills(actor: actor) do
      {:ok, skills} ->
        Enum.map(skills, fn s ->
          %{
            ref: "user:" <> s.id,
            name: s.name,
            description: s.description || "",
            source: :user,
            has_executable_bundle: s.has_executable_bundle
          }
        end)

      _ ->
        []
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/discovery_test.exs`
Expected: PASS (3 tests). If `Magus.Skills.list_skills(actor: actor)` returns a bare list rather than `{:ok, list}` in this Ash version, adjust `user_views/1` to match (and note it); the 1A interface `define :list_skills, action: :read` is a standard read, which returns `{:ok, list}`.

- [ ] **Step 5: Verify warnings-as-errors and commit**

Run: `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`
Then:
```bash
git add lib/magus/skills/discovery.ex test/magus/skills/discovery_test.exs
git commit -m "feat(skills): add per-actor Skills.Discovery merge (built-in + user)"
```

---

### Task 2: Compose the system-prompt skills section from discovery

**Files:**
- Modify: `lib/magus/agents/context/system_prompts.ex` (the `skills_capabilities/1` function ~line 276, and its single call site inside `compose/…` ~line 471)
- Test: `test/magus/agents/context/system_prompts_skills_test.exs`

**Interfaces:**
- Consumes: `Magus.Skills.Discovery.list_for_actor/1`.
- Produces: `Magus.Agents.Context.SystemPrompts.skills_capabilities(loaded_tools, actor)` → a "## Available Skills" markdown section listing built-in plus the actor's user skills, each with its ref. The existing `skills_capabilities/1` remains for callers that pass no actor (built-in only, backward compatible).

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/context/system_prompts_skills_test.exs`:

```elixir
defmodule Magus.Agents.Context.SystemPromptsSkillsTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.SystemPrompts
  alias Magus.Skills

  test "skills_capabilities/2 lists a user's skill with its user: ref" do
    owner = generate(user())
    {:ok, skill} = Skills.create_skill(%{name: "prompt-shown", description: "Shows up"}, actor: owner)

    section = SystemPrompts.skills_capabilities(nil, owner)
    assert section =~ "## Available Skills"
    assert section =~ "prompt-shown"
    assert section =~ "user:" <> skill.id
  end

  test "skills_capabilities/2 with a nil actor still lists built-in skills" do
    section = SystemPrompts.skills_capabilities(nil, nil)
    assert section =~ "## Available Skills"
    assert section =~ "builtin:"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/context/system_prompts_skills_test.exs`
Expected: FAIL (`skills_capabilities/2` undefined).

- [ ] **Step 3: Replace `skills_capabilities` with a discovery-backed builder**

In `lib/magus/agents/context/system_prompts.ex`, find the current function (around line 276):

```elixir
  @spec skills_capabilities(list(String.t()) | nil) :: String.t()
  def skills_capabilities(loaded_tools \\ nil) do
    Magus.Agents.Skills.Registry.get_skills_section(loaded_tools)
  end
```

Replace it with these two clauses plus the private builder:

```elixir
  @doc """
  Skills section for the system prompt. Arity 1 keeps the built-in-only
  behavior for callers without an actor; arity 2 merges built-in skills with
  the actor's accessible user skills via `Magus.Skills.Discovery`, listing
  each with its `load_skill` ref.
  """
  @spec skills_capabilities(list(String.t()) | nil) :: String.t()
  def skills_capabilities(loaded_tools \\ nil) do
    Magus.Agents.Skills.Registry.get_skills_section(loaded_tools)
  end

  @spec skills_capabilities(list(String.t()) | nil, struct() | nil) :: String.t()
  def skills_capabilities(_loaded_tools, actor) do
    actor
    |> Magus.Skills.Discovery.list_for_actor()
    |> build_skills_section()
  end

  defp build_skills_section([]), do: ""

  defp build_skills_section(views) do
    lines =
      Enum.map_join(views, "\n", fn v ->
        "- **#{v.name}** (`#{v.ref}`): #{v.description}"
      end)

    """
    ## Available Skills

    Specialized instructions and tools are organized into skills. Load one with the `load_skill` tool, passing its ref shown in backticks:

    #{lines}

    Load the relevant skill when a request needs it. You can load multiple skills.
    """
  end
```

(Note: the arity-2 form intentionally drops the built-in "(loaded)" annotation that `Registry.get_skills_section/1` applied. `load_skill` already de-duplicates re-loads, so the annotation is not needed for correctness; it can be reintroduced later if desired.)

- [ ] **Step 4: Thread the actor into the compose call site**

In the same file, find the single call to `skills_capabilities(loaded_tools)` inside the `compose/…` function (around line 471, of the form `{:skills, if(load_skills, do: skills_capabilities(loaded_tools))}`). The `compose` function already receives `user` as a parameter (passed from `build/2`). Change that call to pass `user` as the actor:

```elixir
      {:skills, if(load_skills, do: skills_capabilities(loaded_tools, user))}
```

If `compose` does not already have `user` in scope at that point, confirm by reading the `compose(` head: `build/2` calls `compose(identity_context, custom_layer, user, load_skills, skill_context, loaded_tools, …)`, so `user` is the third positional parameter and is in scope. Do not add new parameters.

- [ ] **Step 5: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/context/system_prompts_skills_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 6: Guard against regressions in prompt building**

Run the existing system-prompt tests to confirm the call-site change did not break composition:
Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/context/`
Expected: all pass. Then `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors` (no warnings).

- [ ] **Step 7: Commit**

```bash
git add lib/magus/agents/context/system_prompts.ex test/magus/agents/context/system_prompts_skills_test.exs
git commit -m "feat(skills): build system-prompt skills section from per-actor discovery"
```

---

### Task 3: `load_skill` ref-aware dispatch (built-in + user)

**Files:**
- Modify: `lib/magus/agents/tools/skills/load_skill.ex`
- Test: `test/magus/agents/tools/skills/load_skill_user_test.exs`

**Interfaces:**
- Consumes: `Magus.Skills.get_skill/2`, `Magus.Chat.set_conversation_skill/3`, `Magus.Agents.Tools.ToolBuilder.resolve_skill_tools/1` (all existing).
- Produces: `load_skill` accepts a `skill_name` that may be a ref. Resolution:
  - `"user:" <> id` → load `Magus.Skills.Skill` by id as the context user; persist its `body` to `skill_context` and `requested_tools` to `skill_tools`; return the body plus `__new_tools__` for resolved tools.
  - `"builtin:" <> name` or a bare name → existing built-in path (`Registry.get_skill/1`).

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/tools/skills/load_skill_user_test.exs`:

```elixir
defmodule Magus.Agents.Tools.Skills.LoadSkillUserTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.Skills

  defp conversation_for(owner) do
    # Minimal conversation owned by `owner`. Use the same creation path other
    # tool tests use; a chat conversation with default mode is sufficient.
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)
    conv
  end

  test "loading a user skill by ref persists its body and requested tools" do
    owner = generate(user())
    conv = conversation_for(owner)

    {:ok, skill} =
      Skills.create_skill(
        %{
          name: "loadable",
          description: "d",
          body: "# Loadable\nDo the thing.",
          requested_tools: ["web_search"]
        },
        actor: owner
      )

    context = %{user_id: owner.id, user: owner, conversation_id: conv.id}

    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, context)
    assert result.content =~ "Do the thing."

    {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, actor: owner)
    assert reloaded.skill_context =~ "Do the thing."
    assert "web_search" in (reloaded.skill_tools || [])
  end

  test "a non-owner cannot load another user's skill by ref" do
    owner = generate(user())
    stranger = generate(user())
    conv = conversation_for(stranger)
    {:ok, skill} = Skills.create_skill(%{name: "private-load", description: "d", body: "secret"}, actor: owner)

    context = %{user_id: stranger.id, user: stranger, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, context)
    assert Map.has_key?(result, :error)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/load_skill_user_test.exs`
Expected: FAIL (the `"user:"`-prefixed name is treated as an unknown built-in skill and returns an `:error` map, so the first test's body assertion fails).

- [ ] **Step 3: Add ref-aware dispatch to `load_skill`**

In `lib/magus/agents/tools/skills/load_skill.ex`, replace the `run/2` function with a resolver that branches on the ref, and add the user-skill helpers. Keep the existing `persist_skill/2` and `maybe_attach_new_tools/2` for the built-in path; add parallel helpers for user skills. Replace `run/2`:

```elixir
  @impl true
  def run(params, context) do
    ref = get_param(params, :skill_name)

    case resolve(ref, context) do
      {:builtin, skill} ->
        persist_skill(context, skill)

        result = %{skill: skill.name, description: skill.description, content: skill.content}
        {:ok, maybe_attach_new_tools(result, skill.tools)}

      {:user, skill} ->
        tools = skill.requested_tools || []
        persist_user_skill(context, skill.body, tools)

        result = %{skill: skill.name, description: skill.description || "", content: skill.body || ""}
        {:ok, maybe_attach_new_tools(result, tools)}

      :not_found ->
        available =
          Registry.list_skills() |> Enum.map(&("builtin:" <> &1.name)) |> Enum.sort()

        {:ok, %{error: "Skill '#{ref}' not found", available_skills: available}}
    end
  end

  # Resolve a load_skill ref to its source.
  # "user:<id>" -> DB skill (access-checked as the context user)
  # "builtin:<name>" or a bare name -> registry skill
  defp resolve("user:" <> id, context) do
    actor = get_context_value(context, :user)

    case actor && Magus.Skills.get_skill(id, actor: actor) do
      {:ok, skill} -> {:user, skill}
      _ -> :not_found
    end
  end

  defp resolve("builtin:" <> name, _context), do: registry_lookup(name)
  defp resolve(name, _context) when is_binary(name), do: registry_lookup(name)
  defp resolve(_, _), do: :not_found

  defp registry_lookup(name) do
    case Registry.get_skill(name) do
      {:ok, skill} -> {:builtin, skill}
      _ -> :not_found
    end
  end

  # Persist a user skill's body + requested tool names onto the conversation,
  # mirroring persist_skill/2 but sourced from a Magus.Skills.Skill.
  defp persist_user_skill(context, body, tools) do
    conversation_id = get_context_value(context, :conversation_id)
    body = body || ""

    if conversation_id != nil and body != "" do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing_context = conversation.skill_context || ""
          existing_tools = conversation.skill_tools || []

          # Skip if this exact body is already present (idempotent re-load).
          unless String.contains?(existing_context, body) do
            merged_context =
              if existing_context == "", do: body, else: existing_context <> "\n\n---\n\n" <> body

            merged_tools = Enum.uniq(existing_tools ++ tools)

            Magus.Chat.set_conversation_skill(
              conversation,
              %{skill_context: merged_context, skill_tools: merged_tools},
              authorize?: false
            )
          end

        _ ->
          :ok
      end
    end
  end
```

(The built-in path keeps using the existing `persist_skill/2` and `maybe_attach_new_tools/2` unchanged. `get_context_value/2` is already imported at the top of the module.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/load_skill_user_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Guard built-in load_skill behavior and commit**

Run any existing load_skill test plus a compile check:
```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
```
Expected: all pass, no warnings. Then:
```bash
git add lib/magus/agents/tools/skills/load_skill.ex test/magus/agents/tools/skills/load_skill_user_test.exs
git commit -m "feat(skills): ref-aware load_skill dispatch for user skills"
```

---

### Task 4: End-to-end discovery-to-load integration test

**Files:**
- Test: `test/magus/skills/discovery_load_integration_test.exs`

**Interfaces:**
- Consumes everything from Tasks 1-3. No production code in this task; it proves the pieces compose.

- [ ] **Step 1: Write the integration test**

Create `test/magus/skills/discovery_load_integration_test.exs`:

```elixir
defmodule Magus.Skills.DiscoveryLoadIntegrationTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.SystemPrompts
  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.Skills
  alias Magus.Skills.Discovery

  test "owner discovers a user skill, sees it in the prompt, and loads it by ref" do
    owner = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)

    {:ok, skill} =
      Skills.create_skill(
        %{name: "e2e-skill", description: "End to end", body: "# E2E\nUse me.", requested_tools: ["web_search"]},
        actor: owner
      )

    # Discovery surfaces it with a stable ref.
    ref = "user:" <> skill.id
    assert ref in (Discovery.list_for_actor(owner) |> Enum.map(& &1.ref))

    # The prompt section shows the same ref.
    section = SystemPrompts.skills_capabilities(nil, owner)
    assert section =~ ref

    # Loading by that ref persists the body + tools.
    context = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: ref}, context)
    assert result.content =~ "Use me."

    {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, actor: owner)
    assert reloaded.skill_context =~ "Use me."
    assert "web_search" in (reloaded.skill_tools || [])
  end

  test "a stranger neither discovers nor loads the owner's private skill" do
    owner = generate(user())
    stranger = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: stranger)
    {:ok, skill} = Skills.create_skill(%{name: "e2e-private", description: "d", body: "nope"}, actor: owner)
    ref = "user:" <> skill.id

    refute ref in (Discovery.list_for_actor(stranger) |> Enum.map(& &1.ref))
    refute SystemPrompts.skills_capabilities(nil, stranger) =~ ref

    context = %{user_id: stranger.id, user: stranger, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: ref}, context)
    assert Map.has_key?(result, :error)
  end
end
```

- [ ] **Step 2: Run the test**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/discovery_load_integration_test.exs`
Expected: PASS (2 tests). If `Magus.Chat.create_conversation/2`'s required args differ (e.g. it needs a `chat_mode` or no `title`), adjust the conversation setup to the minimal valid create for this codebase; the rest of the assertions are unaffected.

- [ ] **Step 3: Run the full skills suite and commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/ test/magus/agents/tools/skills/ test/magus/agents/context/
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
```
Expected: all green, no warnings. Then:
```bash
git add test/magus/skills/discovery_load_integration_test.exs
git commit -m "test(skills): end-to-end discovery to load for user skills"
```

---

## Self-Review

- **Spec/scope coverage:** discovery merge (Task 1), per-conversation system-prompt composition with refs (Task 2), `load_skill` ref dispatch for user skills reusing `skill_context`/`skill_tools` (Task 3), and an end-to-end test (Task 4) implement the 1B slice. Bundle materialization, first-run approval, secrets, import, `create_skill`, and the SPA are explicitly deferred to 1C / later. The open `(user_id, name)` uniqueness question is resolved by ref-based dispatch (no constraint added).
- **Placeholders:** none. The two "if the framework differs, adjust" notes (the `list_skills` return shape, the `create_conversation` args) name the exact fallback and are conditional verifications, not unfinished work.
- **Type/interface consistency:** the `view` map keys (`ref`, `name`, `description`, `source`, `has_executable_bundle`) are produced in Task 1 and consumed in Task 2; ref formats (`builtin:`/`user:`) are produced in Task 1 and resolved in Task 3; `skills_capabilities/2` is defined in Task 2 and exercised in Tasks 2 and 4; the persistence fields (`skill_context`, `skill_tools`) match 1A's `Conversation` schema and `load_skill`'s existing built-in path.
- **Reuse:** no new tool modules (user-skill `requested_tools` resolve through the existing `ToolBuilder` Tier-4 path because they land in `conversation.skill_tools`); no schema change; the built-in `load_skill` path is untouched.
