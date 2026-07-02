# User-Managed Skills — Phase 1C-runtime: Materialize, First-Run Approval, Secrets, create_skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a bundled skill safely. When the agent loads a skill that carries executable artifacts, gate it behind a human first-run approval; once approved, materialize the bundle into the conversation's sandbox so the agent can run the scripts. Plus: let an agent bundle its own sandbox artifacts into a reusable skill (`create_skill`), and make a configured sandbox a hard requirement for bundled-skill execution.

**Architecture (enforced cross-turn approval):** A bundled skill's `load_skill` (from 1B) gains a branch: if the skill is recorded as approved on the conversation, materialize it; otherwise raise an approval request (notification + action-card message) and return "pending", stopping the turn. The user's "Approve skill: <id>" reply is recorded onto the conversation by a small, in-pattern extension of the existing approval matcher (`InboxEventPlugin.check_approval_response`) — NOT by the agent — so the gate cannot be bypassed by a misbehaving agent. Materialization writes the bundle's files into `/workspace/.skills/<name>/` via the sandbox orchestrator (idempotent via a marker), and ensures the agent's secrets are present as `/workspace/.env`.

**Tech Stack:** Elixir, Ash 3.x, Jido actions, the sandbox `Orchestrator`, Erlang `:zip`, ExUnit.

## Plan sequence (context)

This is the **runtime half of Phase 1C**, built on 1A (resource), 1B (discovery + `load_skill` dispatch), and 1C-import (the bundle in storage + `Magus.Skills.Import.Unpack`). It produces working software: import an Anthropic skill (1C-import), load it (1B), approve it (this plan), and run its scripts in the sandbox. The SPA UI and Phases 2/3 follow.

## Decisions baked in (and one honest correction)

- **Enforced gate, all conversation types.** Approval is recorded on a new `Conversation.approved_skill_ids` field by the existing approval matcher (a small added branch), so materialization is gated on non-agent-controlled state. This is more than the "zero InboxEventPlugin change" first floated: the matcher gains one skill-approval branch, because the `AgentInboxEvent` path only exists for custom-agent conversations and the gate must also hold in regular conversations.
- **Async, cross-turn.** `load_skill` on an unapproved bundled skill returns `status: "pending"` and stops; the agent resumes after the user approves and re-calls `load_skill`, which now materializes. This matches how `RequestApproval` already works.
- **Materialization is idempotent**, guarded by a `/workspace/.skills/<name>/.materialized` marker so re-loads do not re-write.
- **Secrets are sandbox env vars**: materialization ensures `/workspace/.env` is written from the conversation's agent secrets (the existing `:sandbox_env` mechanism); the skill's instructions tell scripts to `source /workspace/.env`.
- **Capability gating:** when no sandbox provider is configured, bundled skills are surfaced as unavailable and `load_skill` returns a clear message instead of attempting materialization.

## Global Constraints

- Call resources through domain code interfaces; always pass `actor:`. The actor is the conversation owner (`context[:user]`).
- Sandbox calls go through `Magus.Sandbox.Orchestrator` (`write_file/4`, `read_file/3`, `list_files/3`) with `user_id:` in opts; `Magus.Sandbox.Provider.configured?/0` gates bundled execution.
- Reuse `Magus.Skills.Import.Unpack.unpack/1` (1C-import) to expand the archive in-app before writing files into the sandbox; do NOT assume a sandbox unpack primitive.
- Schema change (the new `Conversation` field) goes through `mix ash.codegen --name add_conversation_approved_skill_ids` then `mix ash.migrate` (dev) and `MIX_ENV=test mix ash.migrate` (test). Commit the migration AND the resource snapshot. Never `mix ash.reset`.
- Tests use the worktree command `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. Before committing: `... MIX_ENV=test mix compile --warnings-as-errors`.
- No em dashes.

---

### Task 1: `Conversation.approved_skill_ids` field + record action

**Files:**
- Modify: `lib/magus/chat/conversation.ex` (add attribute + `record_skill_approval` update action)
- Modify: `lib/magus/chat/chat.ex` (add `define :record_skill_approval, ...` if the domain uses code interfaces for conversation updates; otherwise call the action directly)
- Generate: migration via `mix ash.codegen --name add_conversation_approved_skill_ids`
- Test: `test/magus/chat/conversation_skill_approval_test.exs`

**Interfaces:**
- Produces: `conversation.approved_skill_ids :: [Ecto.UUID.t()]` (default `[]`), and an action that appends a skill id idempotently. Expose as `Magus.Chat.record_skill_approval(conversation, %{skill_id: id}, opts)` or via the existing update path.

- [ ] **Step 1: Write the failing test**

Create `test/magus/chat/conversation_skill_approval_test.exs`:

```elixir
defmodule Magus.Chat.ConversationSkillApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  test "record_skill_approval appends a skill id without duplicates" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    id = Ecto.UUID.generate()

    {:ok, c1} = Chat.record_skill_approval(conv, %{skill_id: id}, actor: owner)
    assert id in c1.approved_skill_ids

    {:ok, c2} = Chat.record_skill_approval(c1, %{skill_id: id}, actor: owner)
    assert Enum.count(c2.approved_skill_ids, &(&1 == id)) == 1
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/conversation_skill_approval_test.exs`
Expected: FAIL (`record_skill_approval`/attribute missing).

- [ ] **Step 3: Add the attribute and action**

In `lib/magus/chat/conversation.ex`, add to `attributes do`:

```elixir
    attribute :approved_skill_ids, {:array, :uuid} do
      allow_nil? true
      default []
      public? true
      description "Skill ids the user has approved to run bundled code in this conversation"
    end
```

Add to `actions do`:

```elixir
    update :record_skill_approval do
      require_atomic? false
      argument :skill_id, :uuid, allow_nil?: false

      change fn changeset, _context ->
        id = Ash.Changeset.get_argument(changeset, :skill_id)
        existing = Ash.Changeset.get_attribute(changeset, :approved_skill_ids) || []
        Ash.Changeset.change_attribute(changeset, :approved_skill_ids, Enum.uniq([id | existing]))
      end
    end
```

In `lib/magus/chat/chat.ex`, add the code interface to the `resource Magus.Chat.Conversation do` block:

```elixir
      define :record_skill_approval, action: :record_skill_approval, args: [:skill_id]
```

(If `record_skill_approval` requires a specific actor policy, the conversation owner is the actor; the existing conversation update policies apply. Confirm the owner can run this update; if not, add an `extra_update` allowing the owner, matching how other owner-only conversation updates are authorized.)

- [ ] **Step 4: Generate the migration and run it**

```bash
set -a && source .env && set +a && mix ash.codegen --name add_conversation_approved_skill_ids
set -a && source .env && set +a && mix ash.migrate
set -a && source .env && set +a && MIX_ENV=test mix ash.migrate
```
Confirm the migration only adds the `approved_skill_ids` column to `conversations`.

- [ ] **Step 5: Run the test, compile check, commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/conversation_skill_approval_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/chat/conversation.ex lib/magus/chat/chat.ex priv/repo/migrations priv/resource_snapshots test/magus/chat/conversation_skill_approval_test.exs
git commit -m "feat(skills): Conversation.approved_skill_ids + record_skill_approval"
```

---

### Task 2: Skill-approval request + matcher

**Files:**
- Create: `lib/magus/skills/approval.ex` (request helper)
- Modify: `lib/magus/agents/plugins/inbox_event_plugin.ex` (`check_approval_response/3`: add a skill-approval branch)
- Test: `test/magus/skills/approval_test.exs`

**Interfaces:**
- Produces:
  - `Magus.Skills.Approval.request(conversation_id, skill, user_id) :: :ok` — creates a notification and an action-card approval message whose "Approve" action sends `"Approve skill: <skill_id>"`.
  - `Magus.Skills.Approval.approved?(conversation, skill_id) :: boolean` — `skill_id in conversation.approved_skill_ids`.
  - The matcher records the approval: a user message `"Approve skill: <skill_id>"` appends that id to the conversation via `Magus.Chat.record_skill_approval/3`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/approval_test.exs`:

```elixir
defmodule Magus.Skills.ApprovalTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills.Approval
  alias Magus.Chat

  test "approved? reflects the conversation's approved_skill_ids" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    id = Ecto.UUID.generate()

    refute Approval.approved?(conv, id)
    {:ok, conv} = Chat.record_skill_approval(conv, %{skill_id: id}, actor: owner)
    assert Approval.approved?(conv, id)
  end
end
```

(The matcher branch is integration-tested in Task 6; this unit test pins `approved?/2`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/approval_test.exs`
Expected: FAIL (`Magus.Skills.Approval` undefined).

- [ ] **Step 3: Create the approval helper**

Create `lib/magus/skills/approval.ex`:

```elixir
defmodule Magus.Skills.Approval do
  @moduledoc """
  First-run approval for bundled skills. Requesting creates a notification and
  an action-card message; the user's "Approve skill: <id>" reply is recorded
  onto the conversation by the approval matcher. Materialization gates on
  `approved?/2`.
  """

  @doc "True when the skill is recorded as approved on the conversation."
  def approved?(conversation, skill_id) do
    skill_id in (Map.get(conversation, :approved_skill_ids) || [])
  end

  @doc """
  The phrase the user's approval reply must start with for this skill. Kept in
  one place so the request action-card and the matcher agree.
  """
  def approve_phrase(skill_id), do: "Approve skill: #{skill_id}"

  @doc "Ask the user to approve running a skill's bundled code."
  def request(conversation_id, skill, user_id) do
    question = "Allow the skill \"#{skill.name}\" to run its bundled code in the sandbox?"

    Magus.Notifications.create_notification(
      %{
        user_id: user_id,
        notification_type: :approval_request,
        title: "Skill approval needed",
        body: question,
        target_conversation_id: conversation_id,
        metadata: %{skill_id: skill.id, options: ["Approve", "Reject"]}
      },
      authorize?: false
    )

    :ok
  end
end
```

- [ ] **Step 4: Add the matcher branch**

In `lib/magus/agents/plugins/inbox_event_plugin.ex`, in `check_approval_response/3`, after the existing inbox-event approval handling, add skill-approval recording. Find the `text = signal.data[:text] || signal.data["text"] || ""` line and, alongside the existing logic, add:

```elixir
    maybe_record_skill_approval(text, conversation_id, user_id)
```

and add the private function to the module:

```elixir
  # A user reply "Approve skill: <uuid>" records that skill as approved on the
  # conversation, gating bundled-skill materialization. Non-agent path: this is
  # the only way approval is recorded, so the agent cannot self-approve.
  defp maybe_record_skill_approval("Approve skill: " <> skill_id, conversation_id, user_id)
       when is_binary(conversation_id) do
    with {:ok, user} when not is_nil(user) <- Magus.Accounts.get_user(user_id, authorize?: false),
         {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, actor: user) do
      Magus.Chat.record_skill_approval(conversation, %{skill_id: String.trim(skill_id)}, actor: user)
    end

    :ok
  rescue
    e ->
      require Logger
      Logger.warning("Skill approval record failed: #{inspect(e)}")
      :ok
  end

  defp maybe_record_skill_approval(_text, _conversation_id, _user_id), do: :ok
```

(Confirm the surrounding function signature and that `conversation_id`/`user_id` are in scope where you add the call; the explore confirms `check_approval_response(signal, conversation_id, user_id)` is the function.)

- [ ] **Step 5: Run the unit test, compile, commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/approval_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/skills/approval.ex lib/magus/agents/plugins/inbox_event_plugin.ex test/magus/skills/approval_test.exs
git commit -m "feat(skills): first-run approval request + matcher recording"
```

---

### Task 3: `Magus.Skills.Materializer`

**Files:**
- Create: `lib/magus/skills/materializer.ex`
- Test: `test/magus/skills/materializer_test.exs` (tagged `:sandbox`)

**Interfaces:**
- Consumes: `Magus.Skills.Import.Unpack.unpack/1`, `Magus.Files.Storage.get/1`, `Magus.Sandbox.Orchestrator.write_file/4` + `read_file/3`.
- Produces: `Magus.Skills.Materializer.materialize(conversation_id, skill, user_id) :: {:ok, dir} | {:error, term}`. Writes each bundle file under `/workspace/.skills/<name>/`, idempotent via a `.materialized` marker; ensures `/workspace/.env`. Returns the dir path.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/materializer_test.exs`. Tag it `:sandbox` (runs only when a sandbox provider is configured, like other sandbox tests):

```elixir
defmodule Magus.Skills.MaterializerTest do
  use Magus.ResourceCase, async: false

  @moduletag :sandbox

  alias Magus.Skills.Materializer
  alias Magus.Sandbox

  setup do
    unless Sandbox.Provider.configured?(), do: :ok
    :ok
  end

  test "materializes bundle files into the sandbox and is idempotent" do
    owner = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)

    bytes = build_zip([{"SKILL.md", "---\nname: m\ndescription: d\n---\nb"}, {"scripts/go.py", "print(1)"}])
    {:ok, _} = Magus.Files.Storage.store("skills/#{owner.id}/m.zip", bytes)

    skill = %{id: Ecto.UUID.generate(), name: "m", bundle_path: "skills/#{owner.id}/m.zip"}

    assert {:ok, dir} = Materializer.materialize(conv.id, skill, owner.id)
    assert dir == "/workspace/.skills/m"
    assert {:ok, %{content: "print(1)"}} =
             Sandbox.Orchestrator.read_file(conv.id, "/workspace/.skills/m/scripts/go.py", user_id: owner.id)

    # Second call is a no-op (marker present).
    assert {:ok, _} = Materializer.materialize(conv.id, skill, owner.id)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run the test to verify it fails (or skips without a sandbox)**

Run: `set -a && source .env && set +a && bin/test-e2e-live --include sandbox test/magus/skills/materializer_test.exs` (or the project's sandbox test command). Expected: FAIL (`Materializer` undefined). Without a sandbox provider the `:sandbox` tag skips it; that is acceptable for local runs, but the implementer MUST run it against a configured sandbox before marking done.

- [ ] **Step 3: Implement the materializer**

Create `lib/magus/skills/materializer.ex`:

```elixir
defmodule Magus.Skills.Materializer do
  @moduledoc """
  Writes a bundled skill's files into the conversation's sandbox under
  /workspace/.skills/<name>/. Idempotent via a .materialized marker. Ensures
  the agent's secrets are present as /workspace/.env before scripts run.
  """

  alias Magus.Sandbox.Orchestrator
  alias Magus.Skills.Import.Unpack

  @spec materialize(Ecto.UUID.t(), map, Ecto.UUID.t()) :: {:ok, String.t()} | {:error, term}
  def materialize(conversation_id, skill, user_id) do
    dir = "/workspace/.skills/#{skill.name}"
    marker = "#{dir}/.materialized"

    if materialized?(conversation_id, marker, user_id) do
      {:ok, dir}
    end_or_write(conversation_id, skill, user_id, dir, marker)
  end

  defp end_or_write(conversation_id, skill, user_id, dir, marker) do
    with {:ok, bytes} <- Magus.Files.Storage.get(skill.bundle_path),
         {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(bytes),
         :ok <- write_all(conversation_id, dir, [{"SKILL.md", md} | files], user_id),
         :ok <- ensure_env(conversation_id, user_id),
         {:ok, _} <- Orchestrator.write_file(conversation_id, marker, "ok", user_id: user_id) do
      {:ok, dir}
    end
  end

  defp materialized?(conversation_id, marker, user_id) do
    match?({:ok, _}, Orchestrator.read_file(conversation_id, marker, user_id: user_id))
  end

  defp write_all(conversation_id, dir, files, user_id) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case Orchestrator.write_file(conversation_id, "#{dir}/#{path}", content, user_id: user_id) do
        {:ok, _} -> {:cont, :ok}
        other -> {:halt, normalize(other)}
      end
    end)
  end

  # Ensure the agent's :sandbox_env secrets are available as /workspace/.env so
  # the skill's scripts can `source` them. Mirrors ExecCommand's injection; a
  # conversation without a custom agent simply gets no env file.
  defp ensure_env(conversation_id, user_id) do
    with {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, authorize?: false),
         agent_id when not is_nil(agent_id) <- conversation.custom_agent_id,
         {:ok, env_map} when map_size(env_map) > 0 <-
           Magus.Agents.sandbox_env_map_for_agent(agent_id, authorize?: false) do
      content = Enum.map_join(env_map, "\n", fn {k, v} -> "export #{k}='#{String.replace(v, "'", "'\\''")}'" end)
      Orchestrator.write_file(conversation_id, "/workspace/.env", content, user_id: user_id)
      :ok
    else
      _ -> :ok
    end
  end

  defp normalize({:error, reason, _details}), do: {:error, reason}
  defp normalize(other), do: other
end
```

(Note: the `materialize/3` head's early-return shape is awkward in Elixir; rewrite it cleanly as a single `if materialized?(...) do {:ok, dir} else end_or_write(...) end`. The implementer must make this compile; the logic is: marker present -> `{:ok, dir}`, else write everything. Confirm `Magus.Agents.sandbox_env_map_for_agent/2` arity against `exec_command.ex`, which calls it.)

- [ ] **Step 4: Run the test against a configured sandbox, then commit**

```bash
set -a && source .env && set +a && bin/test-e2e-live --include sandbox test/magus/skills/materializer_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/skills/materializer.ex test/magus/skills/materializer_test.exs
git commit -m "feat(skills): sandbox materializer for bundled skills"
```

---

### Task 4: `load_skill` bundled-skill branch (gate + materialize)

**Files:**
- Modify: `lib/magus/agents/tools/skills/load_skill.ex` (the user-skill branch from 1B)
- Test: `test/magus/agents/tools/skills/load_skill_bundle_test.exs`

**Interfaces:**
- For a user skill with `has_executable_bundle: true`: if `Magus.Skills.Approval.approved?(conversation, skill.id)` -> materialize and return the body plus the materialized dir; else request approval (`Magus.Skills.Approval.request/3`) and return `%{status: "pending", content: body, hint: "..."}`. When `Magus.Sandbox.Provider.configured?/0` is false, return a clear "code execution unavailable" message instead. Prompt-only user skills (no bundle) keep 1B behavior.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/tools/skills/load_skill_bundle_test.exs`:

```elixir
defmodule Magus.Agents.Tools.Skills.LoadSkillBundleTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.{Chat, Skills}

  test "loading an unapproved bundled skill returns pending and does not materialize" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    {:ok, skill} =
      Skills.import_skill(
        %{name: "bundled", description: "d", body: "# B", has_executable_bundle: true, source_format: :skill_md, bundle_path: "skills/x.zip"},
        actor: owner
      )

    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, ctx)
    assert result.status == "pending"
    # body still persisted so the agent has the instructions
    assert result.content =~ "B"
  end

  test "loading an approved bundled skill (no sandbox) reports execution unavailable" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)
    {:ok, skill} =
      Skills.import_skill(
        %{name: "bundled2", description: "d", body: "# B", has_executable_bundle: true, source_format: :skill_md, bundle_path: "skills/x.zip"},
        actor: owner
      )
    {:ok, conv} = Chat.record_skill_approval(conv, %{skill_id: skill.id}, actor: owner)

    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}
    {:ok, result} = LoadSkill.run(%{skill_name: "user:" <> skill.id}, ctx)

    if Magus.Sandbox.Provider.configured?() do
      # With a sandbox, an approved skill materializes (covered in Task 6 E2E).
      assert Map.has_key?(result, :materialized) or Map.has_key?(result, :content)
    else
      assert result[:unavailable] == true or result.content =~ "unavailable"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/load_skill_bundle_test.exs`
Expected: FAIL (the user-skill branch does not yet handle bundles / status pending).

- [ ] **Step 3: Extend the user-skill branch**

In `lib/magus/agents/tools/skills/load_skill.ex`, in the `{:user, skill}` branch of `run/2` (added in 1B), after persisting the body and requested tools, add bundle handling:

```elixir
      {:user, skill} ->
        tools = skill.requested_tools || []
        persist_user_skill(context, skill.body, tools)
        base = %{skill: skill.name, description: skill.description || "", content: skill.body || ""}

        cond do
          not skill.has_executable_bundle ->
            {:ok, maybe_attach_new_tools(base, tools)}

          not Magus.Sandbox.Provider.configured?() ->
            {:ok, Map.merge(base, %{unavailable: true, content: base.content <> "\n\n(This skill requires code execution, which is unavailable on this instance.)"})}

          true ->
            handle_bundled_skill(context, skill, base, tools)
        end
```

Add the helper (uses `Magus.Skills.Approval` and `Magus.Skills.Materializer`):

```elixir
  defp handle_bundled_skill(context, skill, base, tools) do
    conversation_id = get_context_value(context, :conversation_id)
    user_id = get_context_value(context, :user_id)
    {:ok, conversation} = Magus.Chat.get_conversation(conversation_id, authorize?: false)

    if Magus.Skills.Approval.approved?(conversation, skill.id) do
      case Magus.Skills.Materializer.materialize(conversation_id, skill, user_id) do
        {:ok, dir} ->
          enriched = Map.put(base, :materialized, dir)
          enriched = Map.put(enriched, :content, base.content <> "\n\nThis skill is installed at #{dir}. If it needs secrets, `source /workspace/.env` first.")
          {:ok, maybe_attach_new_tools(enriched, tools)}

        {:error, reason} ->
          {:ok, Map.put(base, :error, "Could not install skill: #{inspect(reason)}")}
      end
    else
      Magus.Skills.Approval.request(conversation_id, skill, user_id)

      {:ok,
       Map.merge(base, %{
         status: "pending",
         hint:
           "This skill bundles code that runs in the sandbox. STOP and wait for the user to approve. After they approve, call load_skill again with the same ref to install and use it."
       })}
    end
  end
```

- [ ] **Step 4: Run the test, compile, commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/load_skill_bundle_test.exs test/magus/agents/tools/skills/
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/agents/tools/skills/load_skill.ex test/magus/agents/tools/skills/load_skill_bundle_test.exs
git commit -m "feat(skills): gate bundled load_skill on approval + materialize"
```

---

### Task 5: `create_skill` agent authoring tool

**Files:**
- Create: `lib/magus/agents/tools/skills/create_skill.ex`
- Modify: `lib/magus/agents/tools/tool_builder.ex` (register in `@skill_tool_mapping` and the main toolset so the agent can call it)
- Test: `test/magus/agents/tools/skills/create_skill_test.exs` (tagged `:sandbox` for the read path; a unit path for the no-files case)

**Interfaces:**
- Produces: a Jido action `create_skill` with params `name`, `description`, `body`, `include_paths` (sandbox files/dirs to bundle; `{:or, [{:list, :string}, nil]}`), optional `requested_tools`, `required_secrets`, `runtime_hints`, `workspace_id`. Reads the paths from the sandbox, zips them with a generated `SKILL.md`, and calls `Magus.Skills.Import.import_bundle/2` to persist. Returns the new skill id/name.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/tools/skills/create_skill_test.exs`:

```elixir
defmodule Magus.Agents.Tools.Skills.CreateSkillTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Skills.CreateSkill

  test "create_skill with no include_paths creates a prompt-only skill" do
    owner = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "t"}, actor: owner)
    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}

    {:ok, result} =
      CreateSkill.run(
        %{"name" => "authored", "description" => "made by agent", "body" => "# Authored", "include_paths" => nil},
        ctx
      )

    assert result.name == "authored"
    assert is_binary(result.skill_id)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/create_skill_test.exs`
Expected: FAIL (`CreateSkill` undefined).

- [ ] **Step 3: Implement the tool**

Create `lib/magus/agents/tools/skills/create_skill.ex` (model the Jido shape on `load_skill.ex`):

```elixir
defmodule Magus.Agents.Tools.Skills.CreateSkill do
  use Jido.Action,
    name: "create_skill",
    description: """
    Bundle work you built in the sandbox into a reusable skill. Provide a name,
    a one-line description, the SKILL.md body (instructions), and optionally the
    sandbox file paths to include. The skill becomes available to load later.
    """,
    schema: [
      name: [type: :string, required: true],
      description: [type: :string, required: true],
      body: [type: :string, required: true],
      include_paths: [type: {:or, [{:list, :string}, nil]}, default: nil],
      requested_tools: [type: {:or, [{:list, :string}, nil]}, default: nil],
      workspace_id: [type: {:or, [:string, nil]}, default: nil]
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2, validate_context: 2]

  def display_name, do: "Creating skill..."
  def summarize_output(%{name: n}), do: "Created skill: #{n}"
  def summarize_output(%{error: _}), do: "Could not create skill"
  def summarize_output(_), do: "Done"

  @impl true
  def run(params, context) do
    with {:ok, ctx} <- validate_context(context, [:user_id, :conversation_id]) do
      user = get_context_value(context, :user)
      name = get_param(params, :name)
      include = get_param(params, :include_paths) || []

      with {:ok, files} <- read_sandbox_files(ctx.conversation_id, include, ctx.user_id),
           {:ok, zip} <- build_zip(name, params, files),
           {:ok, skill} <-
             Magus.Skills.Import.import_bundle(zip, actor: user, workspace_id: get_param(params, :workspace_id)) do
        {:ok, %{skill_id: skill.id, name: skill.name}}
      else
        {:error, reason} -> {:ok, %{error: "Could not create skill: #{inspect(reason)}"}}
      end
    else
      {:error, msg} -> {:ok, %{error: msg}}
    end
  end

  defp read_sandbox_files(_conversation_id, [], _user_id), do: {:ok, []}

  defp read_sandbox_files(conversation_id, paths, user_id) do
    results =
      Enum.map(paths, fn p ->
        case Magus.Sandbox.Orchestrator.read_file(conversation_id, p, user_id: user_id) do
          {:ok, %{content: c}} -> {relative(p), c}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  # Bundle paths are stored relative to scripts/ so SKILL.md can reference them.
  defp relative(path), do: "scripts/" <> Path.basename(path)

  defp build_zip(name, params, files) do
    front = "---\nname: #{name}\ndescription: #{get_param(params, :description)}\n"

    allowed =
      case get_param(params, :requested_tools) do
        list when is_list(list) and list != [] -> "allowed-tools: #{Enum.join(list, " ")}\n"
        _ -> ""
      end

    skill_md = front <> allowed <> "---\n" <> (get_param(params, :body) || "")
    entries = [{~c"SKILL.md", skill_md} | Enum.map(files, fn {p, c} -> {String.to_charlist(p), c} end)]

    case :zip.create(~c"skill.zip", entries, [:memory]) do
      {:ok, {_n, bytes}} -> {:ok, bytes}
      other -> other
    end
  end
end
```

In `lib/magus/agents/tools/tool_builder.ex`: add `"create_skill" => CreateSkill` to `@skill_tool_mapping`, alias the module, add it to `@tool_to_category` under `:skills`, and include `CreateSkill` in the `main_tools` list so agents can call it (mirror how `LoadSkill` is wired).

- [ ] **Step 4: Run the test, compile, commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/tools/skills/create_skill_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/agents/tools/skills/create_skill.ex lib/magus/agents/tools/tool_builder.ex test/magus/agents/tools/skills/create_skill_test.exs
git commit -m "feat(skills): create_skill tool to bundle sandbox artifacts into a skill"
```

---

### Task 6: Capability gating in discovery + end-to-end approval/run test

**Files:**
- Modify: `lib/magus/skills/discovery.ex` (annotate bundled skills when the sandbox is unavailable)
- Test: `test/magus/skills/bundled_e2e_test.exs` (tagged `:sandbox`)

**Interfaces:**
- Discovery views gain `runnable: boolean` (false for `has_executable_bundle` skills when `Provider.configured?/0` is false). The system-prompt section (1B) may show "(requires code execution)" for non-runnable bundled skills (optional polish).

- [ ] **Step 1: Write the gating change + E2E test**

In `lib/magus/skills/discovery.ex`, add `runnable: not s.has_executable_bundle or Magus.Sandbox.Provider.configured?()` to the user view map (and `runnable: true` to built-in views).

Create `test/magus/skills/bundled_e2e_test.exs` (tagged `:sandbox`): import a bundle (1C-import), load it (pending), record approval, load again (materializes), then assert the script file exists in the sandbox via `Orchestrator.read_file`. Use the same `build_zip` helper and `bin/test-e2e-live --include sandbox`.

```elixir
defmodule Magus.Skills.BundledE2ETest do
  use Magus.ResourceCase, async: false
  @moduletag :sandbox

  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.{Chat, Skills}
  alias Magus.Sandbox.Orchestrator

  test "import -> load (pending) -> approve -> load (materialized) -> file present" do
    owner = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: owner)

    bytes = build_zip([{"SKILL.md", "---\nname: e2e\ndescription: d\n---\n# E2E\nrun scripts/go.py"}, {"scripts/go.py", "print('ok')"}])
    {:ok, skill} = Skills.Import.import_bundle(bytes, actor: owner)

    ref = "user:" <> skill.id
    ctx = %{user_id: owner.id, user: owner, conversation_id: conv.id}

    {:ok, r1} = LoadSkill.run(%{skill_name: ref}, ctx)
    assert r1.status == "pending"

    {:ok, _} = Chat.record_skill_approval(conv, %{skill_id: skill.id}, actor: owner)

    {:ok, r2} = LoadSkill.run(%{skill_name: ref}, ctx)
    assert r2.materialized == "/workspace/.skills/e2e"
    assert {:ok, %{content: "print('ok')"}} =
             Orchestrator.read_file(conv.id, "/workspace/.skills/e2e/scripts/go.py", user_id: owner.id)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run the E2E against a configured sandbox**

Run: `set -a && source .env && set +a && bin/test-e2e-live --include sandbox test/magus/skills/bundled_e2e_test.exs`
Expected: PASS against a real sandbox. Also run the full non-sandbox skills suite: `... MIX_ENV=test mix test test/magus/skills/ test/magus/agents/tools/skills/`.

- [ ] **Step 3: Compile check and commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/skills/discovery.ex test/magus/skills/bundled_e2e_test.exs
git commit -m "feat(skills): capability gating + bundled-skill end-to-end test"
```

---

## Self-Review

- **Spec/scope coverage:** the enforced cross-turn approval (Tasks 1, 2, 4), sandbox materialization with idempotency and secret env (Task 3), the `create_skill` authoring loop (Task 5), and capability gating + an end-to-end approve-and-run test (Task 6) implement the runtime half of 1C with the approval model you chose. Import is the separate 1C-import plan.
- **Honesty about the design:** the gate adds one branch to the existing approval matcher and one conversation field, because the gate must hold in non-custom-agent conversations too. This is the corrected design (not the "zero plugin change" first floated).
- **Type/interface consistency:** `approved_skill_ids` (Task 1) is read by `Approval.approved?/2` (Task 2) and `load_skill` (Task 4) and written by the matcher (Task 2) and the E2E test (Task 6); `Materializer.materialize/3` (Task 3) is called by `load_skill` (Task 4) and asserted by the E2E (Task 6); `Import.import_bundle/2` (1C-import) is reused by `create_skill` (Task 5) and the E2E (Task 6); `Approval.approve_phrase/1` and the matcher's `"Approve skill: " <> id` literal must agree (keep them in sync, ideally have the action-card use `approve_phrase/1`).
- **Known rough edges flagged for the implementer:** the `materialize/3` early-return must be rewritten as a clean `if/else` to compile; confirm `sandbox_env_map_for_agent/2` arity and the `check_approval_response/3` scope before editing; the sandbox-tagged tests MUST be run against a configured provider before marking those tasks done.
