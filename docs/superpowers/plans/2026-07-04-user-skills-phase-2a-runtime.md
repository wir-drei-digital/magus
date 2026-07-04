# User Skills Phase 2A (Runtime) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user skills triggerable by `/name`, bind approvals to bundle content with recorded provenance, add per-user "always trust", and give skills a per-user secrets vault with declared-key injection.

**Architecture:** Extract the skill-loading logic out of the `LoadSkill` tool into a shared `Magus.Skills.Loader` that both the tool and the message preflight call. Replace the `conversation.approved_skill_ids` array with a `ConversationSkillApproval` join row (content-hash bound, attributed, source-tagged). Add `SkillTrust` and `SandboxSecret` resources. Wire the secrets into materialization and the slash menu into the SPA composer.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, Jido actions, Cloak (AES-256-GCM via `Magus.Integrations.Vault`), SvelteKit 5 + AshTypescript RPC.

## Global Constraints

- **No em dashes** in written content (code comments, docs, copy). Use colons/periods/commas.
- **Never run `mix ash.reset`** (wipes data). Use `mix ash.codegen <name>` then `mix ash.migrate`.
- **Ash nullable tool-schema fields** must be `{:or, [type, nil]}`, never a bare type with `default: nil`.
- **Authorization**: pass a real `actor:`. Only use `authorize?: false` for internal agent-pipeline steps with no acting user (materialization, conversation self-reads), matching the existing skills code.
- **New resources go in the existing `Magus.Skills` domain** (`lib/magus/skills/skills.ex`). No new domain, so the `config/config.exs` + `lib/magus/domains.ex` dual-registration gotcha does NOT apply here.
- **Secret values** use the existing `Magus.Agents.AgentSecret.EncryptedString` Ash type (Cloak AES-256-GCM). Never store or log plaintext secret values.
- **Skill name charset**: `~r/^[a-z0-9-]{1,64}$/` (already enforced on `Skill.name`); slash-command names share this charset.
- **Frontend tests stay structural**: `data-testid` + counts, no brittle label/copy/URL assertions.
- **Regenerate RPC types** with `mix ash_typescript.codegen` after any Ash RPC change; NEVER run it while `mix phx.server` is running (wedges the reloader). Generated files `frontend/src/lib/ash/ash_rpc.ts` and `ash_types.ts` are never hand-edited.
- **CI compiles with `--warnings-as-errors`**: run `MIX_ENV=test mix compile --warnings-as-errors` before considering a task done.

## Shared Interfaces (defined here, referenced by later tasks and by Plans 2B/3)

```elixir
# Task 1
Magus.Skills.Loader.load(ref :: String.t(), context :: map(), opts :: keyword()) ::
  {:ok, map()}
# context: %{conversation_id: uuid, user_id: uuid, user: %User{} | nil}
# opts: [source: :slash_command | :approval_card]  (default :approval_card)
# result map keys: :skill, :description, :content, and optionally
#   :materialized (dir), :status ("pending"), :hint, :unavailable, :error, :__new_tools__

# Task 2
Magus.Skills.Skill  # gains attribute :bundle_sha, :string (nil for prompt-only)

# Task 3
Magus.Skills.record_conversation_approval(%{
  conversation_id: uuid, skill_id: uuid, bundle_sha: String.t() | nil,
  approved_by_id: uuid, source: :slash_command | :approval_card | :trusted
}, actor: user) :: {:ok, struct} | {:error, term}
Magus.Skills.Approval.approved?(conversation :: map(), skill :: map()) :: boolean()
  # true when a row exists for (conversation_id, skill_id) AND
  # (skill.bundle_sha is nil OR row.bundle_sha == skill.bundle_sha)

# Task 5
Magus.Skills.trust_skill(%{skill_id: uuid}, actor: user) :: {:ok, struct} | {:error, term}
Magus.Skills.untrust_skill(trust_id, actor: user) :: {:ok, struct} | {:error, term}
Magus.Skills.Approval.trusted?(user_id :: uuid, skill :: map()) :: boolean()

# Task 6
Magus.Skills.SandboxSecret  # resource: user_id, key, value (encrypted), description
Magus.Skills.sandbox_env_for_user(user_id :: uuid, keys :: [String.t()]) :: %{String.t() => String.t()}
  # returns only the declared keys the user actually has stored
```

---

## File Structure

New backend:
- `lib/magus/skills/loader.ex` — shared skill-load logic (extracted from LoadSkill)
- `lib/magus/skills/conversation_skill_approval.ex` — join resource
- `lib/magus/skills/skill_trust.ex` — per-user trust resource
- `lib/magus/skills/sandbox_secret.ex` — per-user secrets vault resource
- `lib/magus_web/rpc/` — no new controller (RPC actions on the resources)

Modified backend:
- `lib/magus/agents/tools/skills/load_skill.ex` — becomes a thin wrapper over Loader
- `lib/magus/skills/approval.ex` — `approved?/2` reads join row + sha; add `trusted?/2`
- `lib/magus/skills/materializer.ex` — inject declared user secrets into `/workspace/.env`
- `lib/magus/skills/skill.ex` — add `bundle_sha` attribute
- `lib/magus/skills/skills.ex` — register new resources + RPC actions + code interfaces
- `lib/magus/agents/slash_commands.ex` — add `resolve/3` with a skills source
- `lib/magus/agents/plugins/support/preflight.ex` — deterministic skill load on slash match
- `lib/magus/chat/conversation.ex` — drop `approved_skill_ids`; `record_skill_approval` retargets
- `lib/magus/chat/conversation/changes/record_skill_approval.ex` — delete (logic moves to Skills)
- `lib/magus/agents/plugins/inbox_event_plugin.ex` — attribution + join-row write

New frontend:
- `frontend/src/routes/settings/sandbox-secrets/+page.svelte` — vault CRUD
- `frontend/src/lib/stores/skill-slash.svelte.ts` — cached user-skill slash entries (optional helper)

Modified frontend:
- `frontend/src/lib/chat/catalog.ts` — merge user skills into slash entries
- `frontend/src/lib/components/chat/composer.svelte` — sandbox badge on skill entries
- `frontend/src/lib/components/shell/notification-bell.svelte` — declared keys + trust checkbox
- `frontend/src/lib/components/shell/settings-nav.svelte` + `frontend/src/routes/settings/+layout.svelte` — register the page
- `frontend/src/lib/ash/api.ts` — wrappers for secrets, trust, and skill slash entries

Data migrations:
- one structural migration (new tables + `bundle_sha`), one data migration (array to rows + backfill sha), one structural migration (drop the array)

---

## Task 1: Extract `Magus.Skills.Loader` from `LoadSkill`

**Files:**
- Create: `lib/magus/skills/loader.ex`
- Modify: `lib/magus/agents/tools/skills/load_skill.ex`
- Test: `test/magus/skills/loader_test.exs`

**Interfaces:**
- Consumes: existing `Magus.Skills.Approval.approved?/2`, `Magus.Skills.Materializer.materialize/3`, `Magus.Chat.set_conversation_skill/3`, `Magus.Agents.Skills.Registry`, `Magus.Agents.Tools.ToolBuilder.resolve_skill_tools/1`.
- Produces: `Magus.Skills.Loader.load/3` (see Shared Interfaces). `LoadSkill.run/2` delegates to it.

This task is a pure refactor: move `LoadSkill`'s body into `Loader.load/3` verbatim, keeping identical behavior, then make the tool call it. `opts[:source]` is threaded so later tasks (3, slash) can record the right approval source; in this task it is accepted and ignored (approval recording still goes through the existing `Approval.request/3` + inbox path).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/loader_test.exs
defmodule Magus.Skills.LoaderTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Loader

  setup do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "L"}, actor: user)
    %{user: user, conversation: conversation}
  end

  test "loads a builtin skill and persists context onto the conversation",
       %{user: user, conversation: conversation} do
    # brainstorming is a built-in registry skill
    ctx = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, result} = Loader.load("builtin:brainstorming", ctx, [])

    assert result.skill == "brainstorming"
    assert result.content =~ "" and byte_size(result.content) > 0

    {:ok, reloaded} = Magus.Chat.get_conversation(conversation.id, authorize?: false)
    assert reloaded.skill_context =~ result.content
  end

  test "returns not-found for an unknown ref", %{user: user, conversation: conversation} do
    ctx = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, result} = Loader.load("builtin:does-not-exist", ctx, [])
    assert result.error =~ "not found"
    assert is_list(result.available_skills)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/loader_test.exs`
Expected: FAIL with `module Magus.Skills.Loader is not available` / `function Loader.load/3 is undefined`.

- [ ] **Step 3: Create the Loader module**

Move the private logic out of `load_skill.ex` into this module. The context is a plain map here (the tool passes it through). `get_context_value` is replaced by `Map.get`.

```elixir
# lib/magus/skills/loader.ex
defmodule Magus.Skills.Loader do
  @moduledoc """
  Shared skill-loading logic used by both the `load_skill` tool and the message
  preflight (slash-command triggers). Resolves a ref, persists the skill body +
  tool names onto the conversation, and for bundled skills enforces the approval
  gate and materializes into the sandbox.

  `load/3` returns `{:ok, result_map}`; errors are carried inside the map (a
  loaded skill's instructions are user-facing content, never a raised error).
  """

  require Logger

  alias Magus.Agents.Skills.Registry
  alias Magus.Agents.Tools.ToolBuilder

  @type context :: %{
          optional(:user) => struct() | nil,
          conversation_id: Ecto.UUID.t(),
          user_id: Ecto.UUID.t()
        }

  @spec load(String.t(), context(), keyword()) :: {:ok, map()}
  def load(ref, context, opts \\ []) do
    source = Keyword.get(opts, :source, :approval_card)

    case resolve(ref, context) do
      {:builtin, skill} ->
        persist_skill(context, skill)
        result = %{skill: skill.name, description: skill.description, content: skill.content}
        {:ok, maybe_attach_new_tools(result, skill.tools)}

      {:user, skill} ->
        tools = skill.requested_tools || []
        persist_user_skill(context, skill.body, tools)

        base = %{
          skill: skill.name,
          description: skill.description || "",
          content: skill.body || ""
        }

        cond do
          not skill.has_executable_bundle ->
            {:ok, maybe_attach_new_tools(base, tools)}

          not Magus.Sandbox.Provider.configured?() ->
            {:ok,
             Map.merge(base, %{
               unavailable: true,
               content:
                 base.content <>
                   "\n\n(This skill requires code execution, which is unavailable on this instance.)"
             })}

          true ->
            handle_bundled_skill(context, skill, base, tools, source)
        end

      :not_found ->
        available = Registry.list_skills() |> Enum.map(&("builtin:" <> &1.name)) |> Enum.sort()
        {:ok, %{error: "Skill '#{ref}' not found", available_skills: available}}
    end
  end

  defp resolve("user:" <> id, context) do
    actor = Map.get(context, :user)

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

  # source is threaded for slash-invocation approval recording (Task 3 wires the
  # :slash_command path). Here it only distinguishes whether to auto-record.
  defp handle_bundled_skill(context, skill, base, tools, source) do
    conversation_id = Map.get(context, :conversation_id)
    user_id = Map.get(context, :user_id)

    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, conversation} ->
        maybe_autorecord(source, conversation, skill, user_id)

        # Reload to observe an approval just recorded by a slash invocation.
        conversation =
          case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
            {:ok, c} -> c
            _ -> conversation
          end

        if Magus.Skills.Approval.approved?(conversation, skill) do
          materialize(context, skill, base, tools, conversation_id, user_id)
        else
          Magus.Skills.Approval.request(conversation_id, skill, user_id)

          {:ok,
           Map.merge(base, %{
             status: "pending",
             hint:
               "This skill bundles code that runs in the sandbox. STOP and ask the user to approve it by replying exactly: " <>
                 Magus.Skills.Approval.approve_phrase(skill.id) <>
                 ". After they approve, call load_skill again with the same ref to install and use it."
           })}
        end

      _ ->
        {:ok, Map.put(base, :error, "Could not load conversation to check skill approval.")}
    end
  end

  # A user-typed slash invocation IS the human-in-the-loop consent, so record the
  # approval before the gate check (Plan 2A spec, "slash = approval").
  defp maybe_autorecord(:slash_command, conversation, skill, user_id) do
    Magus.Skills.record_conversation_approval(
      %{
        conversation_id: conversation.id,
        skill_id: skill.id,
        bundle_sha: Map.get(skill, :bundle_sha),
        approved_by_id: user_id,
        source: :slash_command
      },
      authorize?: false
    )
  end

  defp maybe_autorecord(_source, _conversation, _skill, _user_id), do: :ok

  defp materialize(context, skill, base, tools, conversation_id, user_id) do
    case Magus.Skills.Materializer.materialize(conversation_id, skill, user_id) do
      {:ok, dir} ->
        enriched =
          base
          |> Map.put(:materialized, dir)
          |> Map.put(
            :content,
            base.content <>
              "\n\nThis skill is installed at #{dir}. If it needs secrets, `source /workspace/.env` first."
          )

        {:ok, maybe_attach_new_tools(enriched, tools)}

      {:error, reason} ->
        {:ok, Map.put(base, :error, "Could not install skill: #{inspect(reason)}")}
    end
  end

  defp persist_context_and_tools(context, content, tools, already_loaded?) do
    conversation_id = Map.get(context, :conversation_id)

    if conversation_id != nil and content not in [nil, ""] do
      case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
        {:ok, conversation} ->
          existing_context = conversation.skill_context || ""
          existing_tools = conversation.skill_tools || []

          unless already_loaded?.(existing_context, existing_tools) do
            merged_context =
              if existing_context == "",
                do: content,
                else: existing_context <> "\n\n---\n\n" <> content

            merged_tools = Enum.uniq(existing_tools ++ tools)

            case Magus.Chat.set_conversation_skill(
                   conversation,
                   %{skill_context: merged_context, skill_tools: merged_tools},
                   authorize?: false
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Logger.warning("persist skill failed: #{inspect(reason)}")
            end
          end

        _ ->
          :ok
      end
    end
  end

  defp persist_user_skill(context, body, tools) do
    body = body || ""

    persist_context_and_tools(context, body, tools, fn existing_context, _existing_tools ->
      String.contains?(existing_context, body)
    end)
  end

  defp persist_skill(context, skill) do
    new_tools = skill.tools || []

    persist_context_and_tools(context, skill.content, new_tools, fn _existing, existing_tools ->
      new_tools != [] and Enum.all?(new_tools, &(&1 in existing_tools))
    end)
  end

  defp maybe_attach_new_tools(result, tool_names) do
    case ToolBuilder.resolve_skill_tools(tool_names) do
      [] -> result
      modules -> Map.put(result, :__new_tools__, modules)
    end
  end
end
```

> Note: `Magus.Skills.record_conversation_approval/2` and `Approval.approved?/2` (2-arg, taking the skill) do not exist yet; Task 3 creates them. To keep Task 1 green in isolation, the `:slash_command` autorecord path is not exercised by Task 1's tests (they use builtin + not-found). If you implement Task 1 before Task 3, temporarily stub `maybe_autorecord(:slash_command, ...)` to `:ok` and `Approval.approved?/2` still has its current 2-arg `(conversation, skill_id)` form. **Simplest ordering: do Task 3 in the same PR branch and keep the calls as written.** The reviewer for Task 1 should confirm the compile succeeds against whatever ordering you choose.

- [ ] **Step 4: Reduce `LoadSkill` to a wrapper**

Replace the entire body of `run/2` and delete the moved private helpers. Keep the `use Jido.Action` block, `display_name/0`, and `summarize_output/1` exactly as they are.

```elixir
# lib/magus/agents/tools/skills/load_skill.ex  (run/2 and imports)
  require Logger

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2]

  def display_name, do: "Loading skill..."

  def summarize_output(%{skill: name}), do: "Loaded: #{name}"
  def summarize_output(%{error: _}), do: "Skill not found"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    ref = get_param(params, :skill_name)

    Magus.Skills.Loader.load(
      ref,
      %{
        conversation_id: get_context_value(context, :conversation_id),
        user_id: get_context_value(context, :user_id),
        user: get_context_value(context, :user)
      },
      source: :approval_card
    )
  end
```

Delete from `load_skill.ex`: `resolve/2`, `registry_lookup/1`, `handle_bundled_skill/3`, `persist_context_and_tools/4`, `persist_user_skill/3`, `persist_skill/2`, `maybe_attach_new_tools/2`, and the now-unused aliases (`Registry`, `ToolBuilder`).

- [ ] **Step 5: Run tests**

Run: `mix test test/magus/skills/loader_test.exs test/magus/agents/tools/skills/`
Expected: PASS. (If a pre-existing `load_skill_test.exs` exists, it must still pass unchanged, proving behavior parity.)

- [ ] **Step 6: Compile clean**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: no warnings (watch for unused-alias warnings in `load_skill.ex`).

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills/loader.ex lib/magus/agents/tools/skills/load_skill.ex test/magus/skills/loader_test.exs
git commit -m "refactor(skills): extract Magus.Skills.Loader from LoadSkill tool"
```

---

## Task 2: Add `bundle_sha` to `Skill` + backfill

**Files:**
- Modify: `lib/magus/skills/skill.ex` (attribute + accept lists + a computed set on import)
- Modify: `lib/magus/skills/import.ex` (set `bundle_sha` at import; it already computes `sha`)
- Create (generated): `priv/repo/migrations/*_add_skill_bundle_sha.exs`
- Test: `test/magus/skills/skill_bundle_sha_test.exs`

**Interfaces:**
- Produces: `Skill.bundle_sha :: String.t() | nil` (sha256 hex of the bundle zip; nil for prompt-only skills). Consumed by Tasks 3/5 (approval binding), Plan 2B (export), Plan 3 (editor re-gate).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/skill_bundle_sha_test.exs
defmodule Magus.Skills.SkillBundleShaTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "import records bundle_sha equal to the zip sha256" do
    user = generate(user())

    bytes =
      build_zip([
        {"SKILL.md", "---\nname: sha-skill\ndescription: d\n---\nbody"},
        {"scripts/go.py", "print(1)"}
      ])

    expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    assert skill.bundle_sha == expected
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/skill_bundle_sha_test.exs`
Expected: FAIL (`key :bundle_sha not found` or the field is nil).

- [ ] **Step 3: Add the attribute**

In `lib/magus/skills/skill.ex`, inside `attributes do`, next to `bundle_path`:

```elixir
    attribute :bundle_sha, :string do
      allow_nil? true
      public? true
      description "sha256 hex of the bundle zip; nil for prompt-only skills. Approvals bind to this."
    end
```

Add `:bundle_sha` to the `:import` action's accept list (the extra bundle fields):

```elixir
    create :import do
      description "Create a skill from an imported bundle (accepts bundle fields)."

      accept @authoring_fields ++
               [
                 :bundle_path,
                 :bundle_backend,
                 :bundle_byte_size,
                 :file_manifest,
                 :has_executable_bundle,
                 :bundle_sha
               ]

      change relate_actor(:user)
    end
```

- [ ] **Step 4: Set it at import**

In `lib/magus/skills/import.ex`, in `do_import_bundle/2`, the `attrs` map already has `sha` in scope. Add `bundle_sha: sha`:

```elixir
      attrs =
        Map.merge(manifest_attrs, %{
          bundle_path: bundle_path,
          bundle_backend: Magus.Files.Storage.backend_name(),
          bundle_byte_size: byte_size(zip_bytes),
          bundle_sha: sha,
          file_manifest: build_manifest(files),
          has_executable_bundle:
            Enum.any?(files, fn {p, _} -> String.starts_with?(p, "scripts/") end),
          workspace_id: workspace_id
        })
```

- [ ] **Step 5: Generate + run the migration**

Run: `mix ash.codegen add_skill_bundle_sha`
Expected: creates a migration adding the `bundle_sha` column to `skills`.
Run: `mix ash.migrate`
Expected: migration applies.

- [ ] **Step 6: Backfill existing rows (data migration)**

Existing content-addressed paths embed the sha: `bundle_path = "skills/#{user_id}/#{sha}.zip"`. Backfill by parsing the basename. Append to the generated migration's `up/0` (below the structural change), and make `down/0` a no-op for the data part:

```elixir
  # in the generated *_add_skill_bundle_sha migration, at the end of up/0:
  def up do
    # ... generated alter table adding bundle_sha ...

    execute("""
    UPDATE skills
    SET bundle_sha = split_part(split_part(bundle_path, '/', -1), '.', 1)
    WHERE bundle_path IS NOT NULL AND bundle_sha IS NULL
    """)
  end
```

Run: `mix ash.migrate` (if not already applied) or re-run against a scratch DB to confirm the `execute/1` is valid SQL. Expected: no error.

- [ ] **Step 7: Run tests + compile**

Run: `mix test test/magus/skills/skill_bundle_sha_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/skills/skill.ex lib/magus/skills/import.ex priv/repo/migrations test/magus/skills/skill_bundle_sha_test.exs
git commit -m "feat(skills): add bundle_sha to Skill, set on import, backfill from path"
```

---

## Task 3: `ConversationSkillApproval` join resource + approval rewrite

**Files:**
- Create: `lib/magus/skills/conversation_skill_approval.ex`
- Modify: `lib/magus/skills/skills.ex` (register resource + code interfaces)
- Modify: `lib/magus/skills/approval.ex` (`approved?/2` reads the join row + sha)
- Modify: `lib/magus/agents/plugins/inbox_event_plugin.ex` (write join row, attribute approver)
- Create (generated): migration for the new table
- Test: `test/magus/skills/conversation_skill_approval_test.exs`

**Interfaces:**
- Consumes: `Skill.bundle_sha` (Task 2).
- Produces: `Magus.Skills.record_conversation_approval/2`, `Magus.Skills.Approval.approved?/2` (see Shared Interfaces).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/conversation_skill_approval_test.exs
defmodule Magus.Skills.ConversationSkillApprovalTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Approval

  setup do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "A"}, actor: user)

    bytes =
      build_zip([{"SKILL.md", "---\nname: gate-skill\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    %{user: user, conversation: conversation, skill: skill}
  end

  test "unapproved skill is not approved?", %{conversation: c, skill: s} do
    refute Approval.approved?(c, s)
  end

  test "recording an approval makes approved? true", %{user: u, conversation: c, skill: s} do
    {:ok, _} =
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: c.id,
          skill_id: s.id,
          bundle_sha: s.bundle_sha,
          approved_by_id: u.id,
          source: :approval_card
        },
        actor: u
      )

    {:ok, c2} = Magus.Chat.get_conversation(c.id, authorize?: false)
    assert Approval.approved?(c2, s)
  end

  test "a bundle_sha change re-gates a previously approved skill",
       %{user: u, conversation: c, skill: s} do
    {:ok, _} =
      Magus.Skills.record_conversation_approval(
        %{conversation_id: c.id, skill_id: s.id, bundle_sha: s.bundle_sha, approved_by_id: u.id, source: :approval_card},
        actor: u
      )

    changed = %{s | bundle_sha: "deadbeef"}
    {:ok, c2} = Magus.Chat.get_conversation(c.id, authorize?: false)
    refute Approval.approved?(c2, changed)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/conversation_skill_approval_test.exs`
Expected: FAIL (`record_conversation_approval/2` undefined; `Approval.approved?/2` arity/behavior).

- [ ] **Step 3: Create the join resource**

```elixir
# lib/magus/skills/conversation_skill_approval.ex
defmodule Magus.Skills.ConversationSkillApproval do
  @moduledoc """
  Records that a skill's bundled code was approved to run in a specific
  conversation. Binds to the approved bundle's sha (a content change re-gates),
  records who approved, and how (slash / card / trust).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversation_skill_approvals"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :skill, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    create :record do
      upsert? true
      upsert_identity :unique_conversation_skill
      upsert_fields [:bundle_sha, :approved_by_id, :source]

      accept [:conversation_id, :skill_id, :bundle_sha, :approved_by_id, :source]
    end
  end

  policies do
    # Recording is done by trusted internal callers (slash preflight, inbox
    # approval matcher) with authorize?: false. Reads for the current user are
    # scoped to conversations they can see.
    policy action_type(:read) do
      authorize_if expr(exists(conversation, user_id == ^actor(:id)))
    end

    policy action(:record) do
      authorize_if always()
    end

    policy action_type(:destroy) do
      authorize_if expr(exists(conversation, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :bundle_sha, :string, allow_nil?: true, public?: true

    attribute :source, :atom do
      allow_nil? false
      default :approval_card
      constraints one_of: [:slash_command, :approval_card, :trusted]
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: false
    belongs_to :skill, Magus.Skills.Skill, allow_nil?: false
    belongs_to :approved_by, Magus.Accounts.User, allow_nil?: true
  end

  identities do
    identity :unique_conversation_skill, [:conversation_id, :skill_id]
  end
end
```

- [ ] **Step 4: Register in the domain**

In `lib/magus/skills/skills.ex`, add to the `resources do` block:

```elixir
    resource Magus.Skills.ConversationSkillApproval do
      define :record_conversation_approval, action: :record
      define :list_conversation_approvals, action: :for_conversation, args: [:conversation_id]
    end
```

- [ ] **Step 5: Rewrite `Approval.approved?/2` + add helper reads**

Replace `approved?/2` in `lib/magus/skills/approval.ex`. It now takes the skill (for the sha) and queries the join row. Keep `approve_phrase/1` and `request/3` unchanged.

```elixir
  require Ash.Query

  @spec approved?(map(), map()) :: boolean()
  @doc """
  True when a `ConversationSkillApproval` row exists for this conversation and
  skill AND the skill is prompt-only (no sha) or its current bundle_sha matches
  the approved sha. A bundle change re-gates.
  """
  def approved?(conversation, skill) do
    conversation_id = Map.get(conversation, :id)
    skill_id = Map.get(skill, :id)
    current_sha = Map.get(skill, :bundle_sha)

    Magus.Skills.ConversationSkillApproval
    |> Ash.Query.filter(conversation_id == ^conversation_id and skill_id == ^skill_id)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [row | _] -> is_nil(current_sha) or row.bundle_sha == current_sha
    end
  end
```

- [ ] **Step 6: Update the inbox approval matcher**

In `lib/magus/agents/plugins/inbox_event_plugin.ex`, `maybe_record_skill_approval/3` currently calls `Magus.Chat.record_skill_approval`. Point it at the new join row, attributing the replying user and binding the skill's current sha:

```elixir
  defp maybe_record_skill_approval("Approve skill: " <> skill_id, conversation_id, user_id)
       when is_binary(conversation_id) do
    skill_id = String.trim(skill_id)

    with {:ok, user} when not is_nil(user) <- Magus.Accounts.get_user(user_id, authorize?: false),
         {:ok, _conversation} <- Magus.Chat.get_conversation(conversation_id, actor: user),
         {:ok, skill} <- Magus.Skills.get_skill(skill_id, actor: user),
         {:ok, _} <-
           Magus.Skills.record_conversation_approval(
             %{
               conversation_id: conversation_id,
               skill_id: skill_id,
               bundle_sha: skill.bundle_sha,
               approved_by_id: user.id,
               source: :approval_card
             },
             authorize?: false
           ) do
      :ok
    else
      error ->
        Logger.warning(
          "Skill approval not recorded (conversation #{conversation_id}): #{inspect(error)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Skill approval record crashed: #{inspect(e)}")
      :ok
  end

  defp maybe_record_skill_approval(_text, _conversation_id, _user_id), do: :ok
```

- [ ] **Step 7: Generate + run migration**

Run: `mix ash.codegen add_conversation_skill_approvals`
Run: `mix ash.migrate`
Expected: creates and applies the `conversation_skill_approvals` table with the unique identity index.

- [ ] **Step 8: Run tests + compile**

Run: `mix test test/magus/skills/conversation_skill_approval_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean. (Note: `Magus.Chat.record_skill_approval` and its change module still exist at this point; Task 4 removes them. `Approval.approved?/2` callers in `Loader` (Task 1) now pass the skill, matching the new arity.)

- [ ] **Step 9: Commit**

```bash
git add lib/magus/skills/conversation_skill_approval.ex lib/magus/skills/skills.ex lib/magus/skills/approval.ex lib/magus/agents/plugins/inbox_event_plugin.ex priv/repo/migrations test/magus/skills/conversation_skill_approval_test.exs
git commit -m "feat(skills): ConversationSkillApproval join row with sha binding + attribution"
```

---

## Task 4: Migrate `approved_skill_ids` array to join rows, then drop it

**Files:**
- Create (generated + hand-edited): a data migration + a structural drop migration
- Modify: `lib/magus/chat/conversation.ex` (remove `approved_skill_ids` attribute + `record_skill_approval` action)
- Delete: `lib/magus/chat/conversation/changes/record_skill_approval.ex`
- Modify: `lib/magus/chat/chat.ex` (remove the `define :record_skill_approval`)
- Test: `test/magus/skills/approval_migration_test.exs`

**Interfaces:**
- Consumes: `Magus.Skills.ConversationSkillApproval` (Task 3), `Skill.bundle_sha` (Task 2).
- Produces: nothing new; removes the legacy array path.

- [ ] **Step 1: Write the data-migration test**

This test drives the backfill logic. Because the array column is being removed from the resource, seed it with raw SQL, run the backfill function, and assert join rows exist.

```elixir
# test/magus/skills/approval_migration_test.exs
defmodule Magus.Skills.ApprovalMigrationTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  alias Magus.Repo

  test "backfill copies array approvals into join rows with the skill's sha" do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "M"}, actor: user)

    bytes =
      build_zip([{"SKILL.md", "---\nname: mig-skill\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    # Simulate a legacy row: write the array column directly (still present in DB
    # until the drop migration). The column exists at test time only if the drop
    # migration has not run; this test asserts the backfill SQL is correct by
    # invoking the shared function against a temp table shape.
    Repo.query!(
      "UPDATE conversations SET approved_skill_ids = $1 WHERE id = $2",
      [[Ecto.UUID.dump!(skill.id)], Ecto.UUID.dump!(conversation.id)]
    )

    Magus.Skills.Migrations.BackfillApprovals.run(Repo)

    rows =
      Magus.Skills.ConversationSkillApproval
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.conversation_id == conversation.id))

    assert [row] = rows
    assert row.skill_id == skill.id
    assert row.bundle_sha == skill.bundle_sha
    assert row.source == :approval_card
    assert row.approved_by_id == user.id
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/approval_migration_test.exs`
Expected: FAIL (`Magus.Skills.Migrations.BackfillApprovals` undefined).

- [ ] **Step 3: Write the backfill module (shared by test + migration)**

```elixir
# lib/magus/skills/migrations/backfill_approvals.ex
defmodule Magus.Skills.Migrations.BackfillApprovals do
  @moduledoc """
  One-shot backfill: copy legacy `conversations.approved_skill_ids` arrays into
  `conversation_skill_approvals` rows, binding each to the skill's current
  bundle_sha and attributing the conversation owner. Idempotent (ON CONFLICT
  DO NOTHING via the unique identity).
  """

  import Ecto.Query

  def run(repo) do
    rows =
      repo.query!("""
      SELECT c.id, c.user_id, unnest(c.approved_skill_ids) AS skill_id
      FROM conversations c
      WHERE c.approved_skill_ids IS NOT NULL
        AND array_length(c.approved_skill_ids, 1) > 0
      """)

    for [conv_id, user_id, skill_id] <- rows.rows do
      sha =
        case repo.query!("SELECT bundle_sha FROM skills WHERE id = $1", [skill_id]) do
          %{rows: [[sha]]} -> sha
          _ -> nil
        end

      repo.query!(
        """
        INSERT INTO conversation_skill_approvals
          (id, conversation_id, skill_id, bundle_sha, approved_by_id, source, inserted_at, updated_at)
        VALUES (uuid_generate_v7(), $1, $2, $3, $4, 'approval_card', now(), now())
        ON CONFLICT (conversation_id, skill_id) DO NOTHING
        """,
        [conv_id, skill_id, sha, user_id]
      )
    end

    :ok
  end

  # Silence unused import when the query/1 path is used exclusively.
  @doc false
  def _ecto_query_marker, do: from(x in "skills", select: x.id)
end
```

> The `import Ecto.Query` + marker keeps the module honest if you later switch to composed queries; if the reviewer prefers, drop the import and the marker and use only `repo.query!`. Either is acceptable; do not leave an unused import warning.

- [ ] **Step 4: Run the backfill test**

Run: `mix test test/magus/skills/approval_migration_test.exs`
Expected: PASS.

- [ ] **Step 5: Generate the drop migration + invoke the backfill**

First author a plain Ecto data migration that calls the backfill (runs while the array column still exists):

```elixir
# priv/repo/migrations/<ts>_backfill_skill_approvals.exs
defmodule Magus.Repo.Migrations.BackfillSkillApprovals do
  use Ecto.Migration

  def up do
    # Data-only migration; runs after conversation_skill_approvals exists
    # (Task 3) and before approved_skill_ids is dropped (next migration).
    Magus.Skills.Migrations.BackfillApprovals.run(repo())
  end

  def down, do: :ok
end
```

Then remove the attribute + action from the resource (Step 6) and let `mix ash.codegen` generate the column drop.

- [ ] **Step 6: Remove the legacy attribute, action, change, and code interface**

In `lib/magus/chat/conversation.ex`, delete the `attribute :approved_skill_ids ...` block and the `update :record_skill_approval do ... end` action.

Delete the file `lib/magus/chat/conversation/changes/record_skill_approval.ex`.

In `lib/magus/chat/chat.ex`, delete the line `define :record_skill_approval, action: :record_skill_approval`.

Grep for other callers to be safe:

Run: `grep -rn "record_skill_approval\|approved_skill_ids" lib/ test/`
Expected: only the new `Magus.Skills.record_conversation_approval` references and the backfill remain; fix any stragglers (there should be none after Task 3 updated the inbox plugin).

- [ ] **Step 7: Generate + run the drop migration**

Run: `mix ash.codegen drop_conversation_approved_skill_ids`
Expected: generates a migration dropping the `approved_skill_ids` column. Confirm the generated migration's `up/0` drops the column and that it is ordered AFTER the backfill migration (rename the timestamp if needed so backfill runs first).
Run: `mix ash.migrate`
Expected: backfill runs, then the column drops.

- [ ] **Step 8: Full skills + chat suite + compile**

Run: `mix test test/magus/skills test/magus/chat && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 9: Commit**

```bash
git add lib/magus/skills/migrations/backfill_approvals.ex lib/magus/chat/conversation.ex lib/magus/chat/chat.ex priv/repo/migrations test/magus/skills/approval_migration_test.exs
git rm lib/magus/chat/conversation/changes/record_skill_approval.ex
git commit -m "refactor(skills): migrate approved_skill_ids array to join rows, drop the array"
```

---

## Task 5: `SkillTrust` (per-user "always allow")

**Files:**
- Create: `lib/magus/skills/skill_trust.ex`
- Modify: `lib/magus/skills/skills.ex` (register + RPC + interfaces)
- Modify: `lib/magus/skills/approval.ex` (add `trusted?/2`)
- Modify: `lib/magus/skills/loader.ex` (trusted skills auto-approve on agent load)
- Create (generated): migration
- Test: `test/magus/skills/skill_trust_test.exs`

**Interfaces:**
- Consumes: `Skill.bundle_sha`, `ConversationSkillApproval` (record on trusted load).
- Produces: `Magus.Skills.trust_skill/1`, `untrust_skill/1`, `Approval.trusted?/2` (see Shared Interfaces).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/skill_trust_test.exs
defmodule Magus.Skills.SkillTrustTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Approval

  setup do
    user = generate(user())

    bytes =
      build_zip([{"SKILL.md", "---\nname: trust-skill\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    %{user: user, skill: skill}
  end

  test "not trusted by default", %{user: u, skill: s} do
    refute Approval.trusted?(u.id, s)
  end

  test "trust then trusted? true; a sha change stales it", %{user: u, skill: s} do
    {:ok, _} = Magus.Skills.trust_skill(%{skill_id: s.id}, actor: u)
    assert Approval.trusted?(u.id, s)

    stale = %{s | bundle_sha: "deadbeef"}
    refute Approval.trusted?(u.id, stale)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/skill_trust_test.exs`
Expected: FAIL (`trust_skill/1` and `Approval.trusted?/2` undefined).

- [ ] **Step 3: Create the resource**

```elixir
# lib/magus/skills/skill_trust.ex
defmodule Magus.Skills.SkillTrust do
  @moduledoc """
  Per-user "always allow this skill" grant. A trusted skill skips the approval
  card in every conversation. Records the bundle sha at grant time; a later
  content change stales the trust (re-prompts once).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "skill_trusts"
    repo Magus.Repo

    references do
      reference :skill, on_delete: :delete
    end
  end

  typescript do
    type_name "SkillTrust"
  end

  actions do
    defaults [:read, :destroy]

    read :my_trusts do
      filter expr(user_id == ^actor(:id))
    end

    create :create do
      argument :skill_id, :uuid, allow_nil?: false
      change set_attribute(:skill_id, arg(:skill_id))
      change relate_actor(:user)
      change Magus.Skills.SkillTrust.Changes.SnapshotSha
    end
  end

  policies do
    policy action_type([:read, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :bundle_sha_at_grant, :string, allow_nil?: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
    belongs_to :skill, Magus.Skills.Skill, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_user_skill, [:user_id, :skill_id]
  end
end
```

```elixir
# lib/magus/skills/skill_trust/changes/snapshot_sha.ex
defmodule Magus.Skills.SkillTrust.Changes.SnapshotSha do
  @moduledoc "Snapshots the skill's current bundle_sha at trust-grant time."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Resolve the skill's current sha in a before_action (single write, no
    # second update action needed) and set it on the changeset.
    Ash.Changeset.before_action(changeset, fn cs ->
      skill_id = Ash.Changeset.get_argument(cs, :skill_id)

      case Magus.Skills.get_skill(skill_id, authorize?: false) do
        {:ok, skill} ->
          Ash.Changeset.change_attribute(cs, :bundle_sha_at_grant, skill.bundle_sha)

        _ ->
          cs
      end
    end)
  end
end
```

- [ ] **Step 4: Register + add `trusted?/2`**

In `lib/magus/skills/skills.ex` `resources do`:

```elixir
    resource Magus.Skills.SkillTrust do
      define :trust_skill, action: :create
      define :untrust_skill, action: :destroy
      define :my_skill_trusts, action: :my_trusts
    end
```

And in `typescript_rpc do`:

```elixir
    resource Magus.Skills.SkillTrust do
      rpc_action :my_skill_trusts, :my_trusts
      rpc_action :trust_skill, :create
      rpc_action :untrust_skill, :destroy
    end
```

In `lib/magus/skills/approval.ex`:

```elixir
  @spec trusted?(Ecto.UUID.t(), map()) :: boolean()
  @doc "True when the user trusts this skill and the trusted sha still matches."
  def trusted?(user_id, skill) do
    current_sha = Map.get(skill, :bundle_sha)

    Magus.Skills.SkillTrust
    |> Ash.Query.filter(user_id == ^user_id and skill_id == ^skill.id)
    |> Ash.read!(authorize?: false)
    |> case do
      [] -> false
      [row | _] -> is_nil(current_sha) or row.bundle_sha_at_grant == current_sha
    end
  end
```

- [ ] **Step 5: Wire trust into the Loader**

In `lib/magus/skills/loader.ex`, `handle_bundled_skill/5`, before the `approved?` branch, auto-record an approval when the user trusts the skill (agent-initiated loads honor trust). Change the approval check to also accept trust:

```elixir
        approved? =
          Magus.Skills.Approval.approved?(conversation, skill) or
            trusted_and_record(conversation, skill, user_id)

        if approved? do
          materialize(context, skill, base, tools, conversation_id, user_id)
        else
          # ... unchanged pending branch ...
        end
```

```elixir
  defp trusted_and_record(conversation, skill, user_id) do
    if user_id && Magus.Skills.Approval.trusted?(user_id, skill) do
      Magus.Skills.record_conversation_approval(
        %{
          conversation_id: conversation.id,
          skill_id: skill.id,
          bundle_sha: Map.get(skill, :bundle_sha),
          approved_by_id: user_id,
          source: :trusted
        },
        authorize?: false
      )

      true
    else
      false
    end
  end
```

- [ ] **Step 6: Migration + tests + compile**

Run: `mix ash.codegen add_skill_trusts && mix ash.migrate`
Run: `mix test test/magus/skills/skill_trust_test.exs test/magus/skills/loader_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills/skill_trust.ex lib/magus/skills/skill_trust/ lib/magus/skills/skills.ex lib/magus/skills/approval.ex lib/magus/skills/loader.ex priv/repo/migrations test/magus/skills/skill_trust_test.exs
git commit -m "feat(skills): SkillTrust per-user always-allow with sha staleness"
```

---

## Task 6: `SandboxSecret` vault + declared-key injection

**Files:**
- Create: `lib/magus/skills/sandbox_secret.ex`
- Modify: `lib/magus/skills/skills.ex` (register + RPC + interfaces + `sandbox_env_for_user/2`)
- Modify: `lib/magus/skills/materializer.ex` (inject declared user secrets)
- Create (generated): migration
- Test: `test/magus/skills/sandbox_secret_test.exs`

**Interfaces:**
- Consumes: `Magus.Agents.AgentSecret.EncryptedString` (Cloak type).
- Produces: `Magus.Skills.SandboxSecret` (CRUD), `Magus.Skills.sandbox_env_for_user/2` (see Shared Interfaces).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/sandbox_secret_test.exs
defmodule Magus.Skills.SandboxSecretTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "stores an encrypted value and returns only declared keys", %{} do
    user = generate(user())

    {:ok, _} =
      Magus.Skills.create_sandbox_secret(%{key: "DEEPL_API_KEY", value: "secret-1"}, actor: user)

    {:ok, _} =
      Magus.Skills.create_sandbox_secret(%{key: "OTHER_KEY", value: "secret-2"}, actor: user)

    env = Magus.Skills.sandbox_env_for_user(user.id, ["DEEPL_API_KEY", "MISSING_KEY"])

    assert env == %{"DEEPL_API_KEY" => "secret-1"}
    refute Map.has_key?(env, "OTHER_KEY")
    refute Map.has_key?(env, "MISSING_KEY")
  end

  test "another user's secrets are not visible", %{} do
    owner = generate(user())
    other = generate(user())
    {:ok, _} = Magus.Skills.create_sandbox_secret(%{key: "K", value: "v"}, actor: owner)

    assert Magus.Skills.sandbox_env_for_user(other.id, ["K"]) == %{}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/sandbox_secret_test.exs`
Expected: FAIL (undefined `create_sandbox_secret/2`, `sandbox_env_for_user/2`).

- [ ] **Step 3: Create the resource**

```elixir
# lib/magus/skills/sandbox_secret.ex
defmodule Magus.Skills.SandboxSecret do
  @moduledoc """
  Per-user sandbox secrets vault. Keys are stored once per user; a skill
  receives only the keys it declares in `required_secrets`, injected into
  /workspace/.env at materialization. Values are encrypted at rest (Cloak
  AES-256-GCM) via the shared EncryptedString type.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "sandbox_secrets"
    repo Magus.Repo
  end

  typescript do
    type_name "SandboxSecret"
  end

  actions do
    defaults [:read, :destroy]

    read :my_secrets do
      filter expr(user_id == ^actor(:id))
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    create :create do
      accept [:key, :value, :description]
      change relate_actor(:user)

      validate match(:key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/),
        message: "must be a valid environment variable name"
    end

    update :update do
      accept [:value, :description]
    end
  end

  policies do
    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true

    attribute :value, Magus.Agents.AgentSecret.EncryptedString do
      allow_nil? false
      # NOT public: the plaintext is never sent to the client. The settings UI
      # is write-only.
    end

    attribute :description, :string, allow_nil?: true, public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_key_per_user, [:user_id, :key]
  end
end
```

- [ ] **Step 4: Register + add `sandbox_env_for_user/2`**

In `lib/magus/skills/skills.ex` `resources do`:

```elixir
    resource Magus.Skills.SandboxSecret do
      define :create_sandbox_secret, action: :create
      define :update_sandbox_secret, action: :update
      define :destroy_sandbox_secret, action: :destroy
      define :my_sandbox_secrets, action: :my_secrets
    end
```

`typescript_rpc do` (note: `value` is not public, so list actions never expose it):

```elixir
    resource Magus.Skills.SandboxSecret do
      rpc_action :my_sandbox_secrets, :my_secrets
      rpc_action :create_sandbox_secret, :create
      rpc_action :update_sandbox_secret, :update
      rpc_action :destroy_sandbox_secret, :destroy
    end
```

Add the injection helper to the domain module body (below `enabled?/0`):

```elixir
  require Ash.Query

  @doc """
  Returns `%{key => value}` for the intersection of `keys` and the user's stored
  sandbox secrets. Only declared keys are ever returned; unknown keys are absent.
  """
  def sandbox_env_for_user(user_id, keys) when is_list(keys) do
    wanted = MapSet.new(keys)

    Magus.Skills.SandboxSecret
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&MapSet.member?(wanted, &1.key))
    |> Map.new(fn s -> {s.key, s.value} end)
  end
```

- [ ] **Step 5: Inject into the Materializer**

In `lib/magus/skills/materializer.ex`, the `ensure_env/2` builds `/workspace/.env` from the agent's secrets. Extend it to merge in the user's declared skill secrets. Change `write_bundle/5` to thread `skill` into env-building, and rename `ensure_env/2` to `ensure_env/3` taking the skill:

```elixir
  defp write_bundle(conversation_id, skill, user_id, dir, marker) do
    with {:ok, bytes} <- Magus.Files.Storage.get(skill.bundle_path),
         {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(bytes),
         :ok <- write_all(conversation_id, dir, [{"SKILL.md", md} | files], user_id),
         :ok <- ensure_env(conversation_id, skill, user_id),
         {:ok, _} <- Orchestrator.write_file(conversation_id, marker, "ok", user_id: user_id) do
      {:ok, dir}
    end
  end

  # Build /workspace/.env from the agent's :sandbox_env secrets (if any) merged
  # with the user's declared skill secrets (only the keys the skill lists in
  # required_secrets). Skill-declared user secrets do NOT override agent secrets
  # on key conflict (the agent owner curated those for this context).
  defp ensure_env(conversation_id, skill, user_id) do
    agent_env = agent_env_map(conversation_id)
    skill_env = declared_skill_env(skill, user_id)
    env = Map.merge(skill_env, agent_env)

    if map_size(env) == 0 do
      :ok
    else
      content =
        Enum.map_join(env, "\n", fn {k, v} ->
          "export #{k}='#{String.replace(v, "'", "'\\''")}'"
        end)

      case Orchestrator.write_file(conversation_id, "/workspace/.env", content, user_id: user_id) do
        {:ok, _} -> :ok
        other -> normalize(other)
      end
    end
  end

  defp agent_env_map(conversation_id) do
    with {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, authorize?: false),
         agent_id when not is_nil(agent_id) <- conversation.custom_agent_id,
         {:ok, env_map} when map_size(env_map) > 0 <-
           Magus.Agents.sandbox_env_map_for_agent(agent_id, authorize?: false) do
      env_map
    else
      _ -> %{}
    end
  end

  defp declared_skill_env(skill, user_id) do
    keys =
      (skill.required_secrets || [])
      |> Enum.map(fn
        %{"key" => k} -> k
        %{key: k} -> k
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if user_id && keys != [], do: Magus.Skills.sandbox_env_for_user(user_id, keys), else: %{}
  end
```

- [ ] **Step 6: Migration + tests + compile**

Run: `mix ash.codegen add_sandbox_secrets && mix ash.migrate`
Run: `mix test test/magus/skills/sandbox_secret_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills/sandbox_secret.ex lib/magus/skills/skills.ex lib/magus/skills/materializer.ex priv/repo/migrations test/magus/skills/sandbox_secret_test.exs
git commit -m "feat(skills): per-user SandboxSecret vault with declared-key injection"
```

---

## Task 7: Slash-command resolution (backend)

**Files:**
- Modify: `lib/magus/agents/slash_commands.ex` (add `resolve/3` with a skills source)
- Modify: `lib/magus/agents/plugins/support/preflight.ex` (deterministic skill load on slash match)
- Test: `test/magus/agents/slash_commands_skills_test.exs`, `test/magus/agents/preflight_slash_skill_test.exs`

**Interfaces:**
- Consumes: `Magus.Skills.Discovery.list_for_actor/1` (returns views with `ref`, `name`, `runnable`), `Magus.Skills.Loader.load/3` (Task 1).
- Produces: `SlashCommands.resolve/3` returning `{:skill, ref} | {:command, instruction} | :none` plus the remaining text.

- [ ] **Step 1: Write the failing test (resolution)**

```elixir
# test/magus/agents/slash_commands_skills_test.exs
defmodule Magus.Agents.SlashCommandsSkillsTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.SlashCommands

  test "resolves a user skill name to a skill ref, agent commands win, globals lose" do
    user = generate(user())

    bytes = build_zip([{"SKILL.md", "---\nname: my-skill\ndescription: d\n---\nb"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    {result, remaining} =
      SlashCommands.resolve("/my-skill do the thing", [], actor: user, conversation: nil)

    assert {:skill, "user:" <> id} = result
    assert id == skill.id
    assert remaining == "do the thing"
  end

  test "unknown slash falls through to none with original text preserved" do
    user = generate(user())
    {result, remaining} = SlashCommands.resolve("/nope hi", [], actor: user, conversation: nil)
    assert result == :none
    assert remaining == "/nope hi"
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/agents/slash_commands_skills_test.exs`
Expected: FAIL (`SlashCommands.resolve/3` undefined).

- [ ] **Step 3: Add `resolve/3`**

Append to `lib/magus/agents/slash_commands.ex`. It parses the leading `/name`, checks agent commands first, then user skills (by name via Discovery), then globals. Returns a tagged result plus remaining text.

```elixir
  @doc """
  Resolve a leading slash command against agent commands, then the actor's
  runnable skills, then globals.

  Returns `{result, remaining_text}` where result is:
    * `{:command, instruction_string}` for a matched agent/global command
    * `{:skill, ref}` for a matched runnable user skill ("user:<id>")
    * `:none` when nothing matched (remaining_text is the original text)
  """
  def resolve(text, agent_commands, opts \\ [])

  def resolve("/" <> rest, agent_commands, opts) do
    {command_name, remaining} =
      case String.split(rest, ~r/\s/, parts: 2) do
        [name] -> {name, ""}
        [name, tail] -> {name, String.trim(tail)}
      end

    cond do
      command = Enum.find(agent_commands, &(to_string(&1.name) == command_name)) ->
        {{:command, "<instruction>#{command.instruction}</instruction>"}, remaining}

      ref = skill_ref(command_name, opts[:actor]) ->
        {{:skill, ref}, remaining}

      command = Enum.find(@global_commands, &(&1.name == command_name)) ->
        {{:command, "<instruction>#{command.instruction}</instruction>"}, remaining}

      true ->
        {:none, "/" <> rest}
    end
  end

  def resolve(text, _agent_commands, _opts), do: {:none, text || ""}

  defp skill_ref(_name, nil), do: nil

  defp skill_ref(name, actor) do
    Magus.Skills.Discovery.list_for_actor(actor)
    |> Enum.find(fn view -> view.source == :user and view.runnable and view.name == name end)
    |> case do
      nil -> nil
      view -> view.ref
    end
  end
```

- [ ] **Step 4: Run resolution test**

Run: `mix test test/magus/agents/slash_commands_skills_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing preflight test**

```elixir
# test/magus/agents/preflight_slash_skill_test.exs
defmodule Magus.Agents.PreflightSlashSkillTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Plugins.Support.Preflight

  test "a /skill message deterministically loads a prompt-only skill and records approval on bundled ones" do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{title: "P"}, actor: user)

    bytes =
      build_zip([{"SKILL.md", "---\nname: pf-skill\ndescription: d\n---\nSKILL BODY MARKER"}])

    {:ok, _skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    # The unit under test is the slash-skill hook. Call the exposed helper that
    # preflight uses (Step 6 extracts it as a public function for testability).
    text =
      Preflight.apply_slash_skill(
        "/pf-skill please run",
        conversation.id,
        user
      )

    # Prompt-only skill body is now on the conversation; the returned text is the
    # user's residual message.
    assert text == "please run"
    {:ok, reloaded} = Magus.Chat.get_conversation(conversation.id, authorize?: false)
    assert reloaded.skill_context =~ "SKILL BODY MARKER"
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 6: Integrate into preflight**

In `lib/magus/agents/plugins/support/preflight.ex`, replace the existing slash block (the `SlashCommands.parse` call around line 43) with a resolve that also handles skills. Extract a testable public helper `apply_slash_skill/3`.

Replace:

```elixir
    agent_slash_commands = get_agent_slash_commands(conversation)
    {slash_instruction, parsed_text} = SlashCommands.parse(raw_text, agent_slash_commands)

    text =
      if slash_instruction do
        slash_instruction <> "\n" <> parsed_text
      else
        parsed_text
      end
```

with:

```elixir
    agent_slash_commands = get_agent_slash_commands(conversation)
    actor = load_actor(conversation)

    text =
      case SlashCommands.resolve(raw_text, agent_slash_commands, actor: actor, conversation: conversation) do
        {{:command, instruction}, remaining} ->
          instruction <> "\n" <> remaining

        {{:skill, ref}, remaining} ->
          load_slash_skill(ref, conversation_id, actor)
          remaining

        {:none, remaining} ->
          remaining
      end
```

Add the helpers (public `apply_slash_skill/3` wraps `load_slash_skill/3` for tests):

```elixir
  @doc false
  # Test seam: resolve + load a slash skill, returning the residual user text.
  def apply_slash_skill(raw_text, conversation_id, actor) do
    case SlashCommands.resolve(raw_text, [], actor: actor, conversation: nil) do
      {{:skill, ref}, remaining} ->
        load_slash_skill(ref, conversation_id, actor)
        remaining

      {_other, remaining} ->
        remaining
    end
  end

  defp load_slash_skill(ref, conversation_id, actor) do
    Magus.Skills.Loader.load(
      ref,
      %{conversation_id: conversation_id, user_id: actor && actor.id, user: actor},
      source: :slash_command
    )
  end

  defp load_actor(nil), do: nil
  defp load_actor(conversation) do
    case Magus.Accounts.get_user(conversation.user_id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end
```

> If `preflight.ex` already loads the acting user elsewhere, reuse that binding instead of `load_actor/1` to avoid a duplicate query. Confirm during implementation by reading the surrounding function.

- [ ] **Step 7: Run tests + compile**

Run: `mix test test/magus/agents/slash_commands_skills_test.exs test/magus/agents/preflight_slash_skill_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean. Confirm existing preflight/slash tests still pass: `mix test test/magus/agents`.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/agents/slash_commands.ex lib/magus/agents/plugins/support/preflight.ex test/magus/agents/slash_commands_skills_test.exs test/magus/agents/preflight_slash_skill_test.exs
git commit -m "feat(skills): deterministic /skill slash triggers via SlashCommands.resolve + preflight"
```

---

## Task 8: RPC + SPA slash menu (skills in the composer)

**Files:**
- Modify: `lib/magus/skills/skills.ex` (add an RPC read that returns runnable skill slash entries) OR reuse `my_skills`
- Modify: `frontend/src/lib/ash/api.ts` (skill slash entries)
- Modify: `frontend/src/lib/chat/catalog.ts` (merge skills into slash entries)
- Modify: `frontend/src/lib/components/chat/composer.svelte` (sandbox badge)
- Regenerate: `frontend/src/lib/ash/ash_rpc.ts`, `ash_types.ts`
- Test: `frontend/tests/skills-slash.spec.ts`

**Interfaces:**
- Consumes: `mySkills()` (existing api.ts wrapper returns `SkillSummary[]` with `name`, `hasExecutableBundle`).
- Produces: slash entries merged into the composer dropdown.

- [ ] **Step 1: Add a skill-slash cache + merge (frontend)**

In `frontend/src/lib/chat/catalog.ts`, add a cached fetch of the user's skills and a merged getter. The composer already renders `SlashCommandEntry[]`; extend the entry with an optional `sandbox` flag.

```typescript
// catalog.ts additions
import { mySkills, type SkillSummary } from '$lib/ash/api';

let userSkillsEntry: Entry<SkillSummary[]> | null = null;

export function cachedUserSkills(): Promise<RpcResult<SkillSummary[]>> {
	if (fresh(userSkillsEntry)) return userSkillsEntry.promise;
	const entry: Entry<SkillSummary[]> = {
		at: Date.now(),
		promise: mySkills().then((result) => {
			if (!result.success && userSkillsEntry === entry) userSkillsEntry = null;
			return result;
		})
	};
	userSkillsEntry = entry;
	return entry.promise;
}

/** Invalidate after skill create/import/delete so the composer reflects it. */
export function invalidateUserSkills(): void {
	userSkillsEntry = null;
}
```

- [ ] **Step 2: Extend the composer to include skills**

In `frontend/src/lib/components/chat/composer.svelte`, where slash commands are loaded and rendered, fetch skills alongside commands and append them as entries carrying a `sandbox` flag. Add the type locally:

```typescript
type SlashRow = { name: string; title: string; icon: string | null; sandbox?: boolean };
```

In the `$effect` that loads `cachedSlashCommands`, also load `cachedUserSkills()` and map its data into `SlashRow[]` with `sandbox: skill.hasExecutableBundle`, then concatenate. Filter by the current typed prefix exactly as the existing command list does.

In the dropdown markup (the `{#each slashCommands as command}` block), add a badge:

```svelte
		<span class="flex-1">{command.title}</span>
		{#if command.sandbox}
			<span
				class="ml-1 rounded bg-amber-100 px-1 py-px text-[9px] font-semibold text-amber-700 dark:bg-amber-950 dark:text-amber-400"
				data-testid="slash-sandbox-badge"
			>
				sandbox
			</span>
		{/if}
		<span class="ml-2 text-xs font-normal text-muted-foreground">/{command.name}</span>
```

- [ ] **Step 3: Regenerate RPC types (no phx.server running)**

Run: `set -a && source .env && set +a && mix ash_typescript.codegen`
Expected: `mySkills` already exists in `ash_rpc.ts`; no new backend RPC is strictly required for this task. If you added a dedicated slash RPC action, confirm it appears.

- [ ] **Step 4: Playwright smoke**

```typescript
// frontend/tests/skills-slash.spec.ts
import { test, expect } from '@playwright/test';
import { mockRpc } from './helpers';

test('typing / lists a user skill with a sandbox badge', async ({ page }) => {
	await mockRpc(page, {
		mySkills: [
			{ id: 's1', name: 'my-skill', displayName: null, description: 'd', requestedTools: [], version: null, license: null, sourceFormat: 'skill_md', hasExecutableBundle: true, isSharedToWorkspace: false, workspaceId: null, isFavorited: false, body: 'b' }
		],
		mergedSlashCommands: []
	});
	await page.goto('/chat');
	await page.getByTestId('composer-input').fill('/my');
	await expect(page.getByTestId('composer-slash-command')).toContainText('my-skill');
	await expect(page.getByTestId('slash-sandbox-badge')).toBeVisible();
});
```

> Adjust `mockRpc` shape and composer input `data-testid` to the repo's existing Playwright helpers (see `frontend/tests/skills.spec.ts` for the established pattern). If the composer input lacks a testid, use its placeholder text selector as the existing tests do.

- [ ] **Step 5: Run frontend checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-slash.spec.ts`
Expected: no type errors; the smoke test passes.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/chat/catalog.ts frontend/src/lib/components/chat/composer.svelte frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts frontend/tests/skills-slash.spec.ts
git commit -m "feat(skills): user skills in the composer slash menu with sandbox badge"
```

---

## Task 9: Approval card shows declared keys + trust checkbox (SPA)

**Files:**
- Modify: `lib/magus/skills/approval.ex` (`request/3` includes declared keys in notification metadata)
- Modify: `frontend/src/lib/components/shell/notification-bell.svelte`
- Modify: `frontend/src/lib/ash/api.ts` (trust wrappers)
- Test: `frontend/tests/skills-approval-card.spec.ts`

**Interfaces:**
- Consumes: `Magus.Skills.trust_skill/1` (Task 5), the notification metadata pipeline (already carries `approve_phrase`; Plan 1 fix added metadata to the live payload).
- Produces: an approval card that lists the skill's declared secret keys and offers "Always allow".

- [ ] **Step 1: Include declared keys in the approval request**

In `lib/magus/skills/approval.ex`, `request/3`, add the declared keys and skill id to metadata:

```elixir
    declared_keys =
      (skill.required_secrets || [])
      |> Enum.map(fn
        %{"key" => k} -> k
        %{key: k} -> k
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    # ... in the metadata map:
             metadata: %{
               skill_id: skill.id,
               approve_phrase: approve_phrase(skill.id),
               declared_secret_keys: declared_keys,
               options: ["Approve", "Reject"]
             }
```

- [ ] **Step 2: Add trust wrappers to api.ts**

```typescript
// frontend/src/lib/ash/api.ts  (Skills section)
export function trustSkill(skillId: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.trustSkill({ input: { skillId }, fields: ['id'], ...opts }));
}

export function untrustSkill(trustId: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.untrustSkill({ identity: trustId, ...opts }));
}
```

- [ ] **Step 3: Extend the approval card**

In `frontend/src/lib/components/shell/notification-bell.svelte`, inside the `data-testid="approval-card"` block, after the body span, render declared keys (from `group.head.metadata?.declared_secret_keys`) and a trust checkbox. Wire the checkbox so that approving-with-trust also calls `trustSkill(metadata.skill_id)`.

```svelte
					{#if Array.isArray(group.head.metadata?.declared_secret_keys) && group.head.metadata.declared_secret_keys.length > 0}
						<div class="mt-1 flex flex-wrap gap-1" data-testid="approval-declared-keys">
							{#each group.head.metadata.declared_secret_keys as key (key)}
								<span class="rounded bg-secondary px-1 py-px font-mono text-[9px] text-secondary-foreground">{key}</span>
							{/each}
						</div>
					{/if}
					<label class="mt-1 flex items-center gap-1.5 text-[11px] text-muted-foreground">
						<input type="checkbox" bind:checked={trustChecked[group.head.id]} data-testid="approval-trust" />
						Always allow this skill
					</label>
```

In the script, add `let trustChecked = $state<Record<string, boolean>>({});` and in `approve(item)`, before/after sending the phrase, if `trustChecked[item.id]` and `item.metadata?.skill_id`, call `await trustSkill(String(item.metadata.skill_id))`.

- [ ] **Step 4: Playwright smoke (structural)**

```typescript
// frontend/tests/skills-approval-card.spec.ts
import { test, expect } from '@playwright/test';
// Seed one approval_request notification with declared_secret_keys via the
// mock feed (follow the existing notification test's seeding pattern).

test('approval card shows declared keys and a trust checkbox', async ({ page }) => {
	// ... seed a notification whose metadata.declared_secret_keys = ['DEEPL_API_KEY']
	await page.goto('/chat');
	await page.getByTestId('notification-bell').click();
	await expect(page.getByTestId('approval-card')).toBeVisible();
	await expect(page.getByTestId('approval-declared-keys')).toContainText('DEEPL_API_KEY');
	await expect(page.getByTestId('approval-trust')).toBeVisible();
});
```

> Reuse the notification-seeding approach from the existing bell tests. If the suite seeds via a store injection rather than RPC mock, follow that.

- [ ] **Step 5: Checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-approval-card.spec.ts`
Run (backend): `mix test test/magus/skills/approval_test.exs` (add an assertion that `declared_secret_keys` is present in the created notification's metadata if a test exists; otherwise extend the approval test).
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/skills/approval.ex frontend/src/lib/components/shell/notification-bell.svelte frontend/src/lib/ash/api.ts frontend/tests/skills-approval-card.spec.ts
git commit -m "feat(skills): approval card lists declared secret keys + always-allow trust"
```

---

## Task 10: Sandbox secrets settings page (SPA)

**Files:**
- Create: `frontend/src/routes/settings/sandbox-secrets/+page.svelte`
- Modify: `frontend/src/lib/components/shell/settings-nav.svelte` (nav entry)
- Modify: `frontend/src/routes/settings/+layout.svelte` (`SECTION_LABELS`)
- Modify: `frontend/src/lib/ash/api.ts` (secrets wrappers)
- Test: `frontend/tests/sandbox-secrets.spec.ts`

**Interfaces:**
- Consumes: `Magus.Skills.SandboxSecret` RPC actions (Task 6).
- Produces: a write-only CRUD page for the vault.

- [ ] **Step 1: Add secrets wrappers to api.ts**

```typescript
// frontend/src/lib/ash/api.ts
export type SandboxSecretEntry = { id: string; key: string; description: string | null; insertedAt: string };

const SANDBOX_SECRET_FIELDS: rpc.MySandboxSecretsFields = ['id', 'key', 'description', 'insertedAt'];

export function mySandboxSecrets(): Promise<RpcResult<SandboxSecretEntry[]>> {
	return run((opts) => rpc.mySandboxSecrets({ fields: SANDBOX_SECRET_FIELDS, ...opts }));
}

export function createSandboxSecret(input: { key: string; value: string; description?: string }): Promise<RpcResult<SandboxSecretEntry>> {
	return run((opts) => rpc.createSandboxSecret({ input, fields: SANDBOX_SECRET_FIELDS, ...opts }));
}

export function updateSandboxSecret(id: string, input: { value: string; description?: string }): Promise<RpcResult<SandboxSecretEntry>> {
	return run((opts) => rpc.updateSandboxSecret({ identity: id, input, fields: SANDBOX_SECRET_FIELDS, ...opts }));
}

export function destroySandboxSecret(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroySandboxSecret({ identity: id, ...opts }));
}
```

- [ ] **Step 2: Register the settings section**

In `frontend/src/lib/components/shell/settings-nav.svelte`, add to `sections` (choose an icon already imported, e.g. `KeyRound`):

```typescript
	{ id: 'sandbox-secrets', label: 'Sandbox secrets', icon: KeyRound },
```

In `frontend/src/routes/settings/+layout.svelte`, add to `SECTION_LABELS`:

```typescript
	'sandbox-secrets': 'Sandbox secrets',
```

- [ ] **Step 3: Build the page (write-only values)**

Mirror `frontend/src/routes/settings/api-tokens/+page.svelte`: load `mySandboxSecrets()` on mount, list keys (never values), an "Add secret" form (key + value + description), and a delete-with-confirm. Editing a secret only re-enters a value.

```svelte
<!-- frontend/src/routes/settings/sandbox-secrets/+page.svelte -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { mySandboxSecrets, createSandboxSecret, destroySandboxSecret, type SandboxSecretEntry } from '$lib/ash/api';

	let secrets = $state<SandboxSecretEntry[]>([]);
	let newKey = $state('');
	let newValue = $state('');
	let error = $state<string | null>(null);

	onMount(load);

	async function load() {
		const r = await mySandboxSecrets();
		if (r.success) secrets = r.data;
	}

	async function add() {
		error = null;
		const r = await createSandboxSecret({ key: newKey.trim(), value: newValue });
		if (r.success) {
			newKey = '';
			newValue = '';
			await load();
		} else {
			error = r.errors[0]?.message ?? 'Failed to add secret';
		}
	}

	async function remove(id: string) {
		const r = await destroySandboxSecret(id);
		if (r.success) await load();
	}
</script>

<div data-testid="sandbox-secrets-page" class="space-y-4">
	<div>
		<h2 class="text-sm font-medium">Sandbox secrets</h2>
		<p class="text-xs text-muted-foreground">
			Stored once per account and injected into a skill's sandbox only when the skill declares the key. Values are write-only.
		</p>
	</div>

	<form class="flex gap-2" onsubmit={(e) => { e.preventDefault(); void add(); }}>
		<input class="wb-input" placeholder="KEY_NAME" bind:value={newKey} data-testid="secret-key" />
		<input class="wb-input" type="password" placeholder="value" bind:value={newValue} data-testid="secret-value" />
		<button class="wb-pill-btn" type="submit" data-testid="secret-add">Add</button>
	</form>
	{#if error}<p class="text-xs text-destructive">{error}</p>{/if}

	<ul data-testid="secret-list" class="divide-y rounded-xl border border-input">
		{#each secrets as secret (secret.id)}
			<li class="flex items-center justify-between px-3 py-2">
				<span class="font-mono text-xs">{secret.key}</span>
				<button class="text-xs text-destructive" onclick={() => void remove(secret.id)} data-testid="secret-delete">Delete</button>
			</li>
		{/each}
	</ul>
</div>
```

> Use the repo's real input/button classes (`wb-input`, `wb-pill-btn` may differ; copy from api-tokens page). Keep values out of any list response and out of the DOM after submit.

- [ ] **Step 4: Regenerate types + Playwright smoke**

Run: `set -a && source .env && set +a && mix ash_typescript.codegen`

```typescript
// frontend/tests/sandbox-secrets.spec.ts
import { test, expect } from '@playwright/test';
import { mockRpc } from './helpers';

test('lists secret keys and offers add', async ({ page }) => {
	await mockRpc(page, { mySandboxSecrets: [{ id: 'k1', key: 'DEEPL_API_KEY', description: null, insertedAt: '2026-07-04T00:00:00Z' }] });
	await page.goto('/settings/sandbox-secrets');
	await expect(page.getByTestId('secret-list')).toContainText('DEEPL_API_KEY');
	await expect(page.getByTestId('secret-add')).toBeVisible();
});
```

- [ ] **Step 5: Checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/sandbox-secrets.spec.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/routes/settings/sandbox-secrets frontend/src/lib/components/shell/settings-nav.svelte frontend/src/routes/settings/+layout.svelte frontend/src/lib/ash/api.ts frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts frontend/tests/sandbox-secrets.spec.ts
git commit -m "feat(skills): sandbox secrets settings page (write-only vault CRUD)"
```

---

## Task 11: Live E2E for the slash + secrets runtime

**Files:**
- Create: `test/e2e_live/skills_slash_secrets_test.exs`

**Interfaces:**
- Consumes: the full runtime (Loader, ConversationSkillApproval, SandboxSecret injection), the Daytona sandbox.

This is sandbox-tagged; it runs only with real provider creds (`bin/test-e2e-live <file> --include sandbox`) and skips gracefully otherwise, following `test/e2e_live/skills_bundled_test.exs`.

- [ ] **Step 1: Write the E2E test**

```elixir
# test/e2e_live/skills_slash_secrets_test.exs
defmodule Magus.LiveE2E.SkillsSlashSecretsTest do
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Tools.Sandbox.RunCode

  @moduletag :sandbox
  @moduletag timeout: 240_000

  setup %{user: user, model: model} do
    conversation = create_conversation(user, model)
    context = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, probe} = RunCode.run(%{"code" => "print('probe')"}, context)
    %{conversation: conversation, context: context, sandbox?: probe[:success] == true}
  end

  test "slash-triggered bundled skill records slash approval, materializes, and sources declared secret",
       %{user: user, conversation: conversation, sandbox?: sandbox?} do
    if sandbox? do
      {:ok, _} =
        Magus.Skills.create_sandbox_secret(%{key: "MY_SKILL_KEY", value: "sk-live-42"}, actor: user)

      bytes =
        build_zip([
          {"SKILL.md",
           "---\nname: slash-skill\ndescription: d\nmetadata:\n  x-magus: '{\"required_secrets\":[{\"key\":\"MY_SKILL_KEY\"}]}'\n---\nrun scripts/show.sh"},
          {"scripts/show.sh", "#!/bin/sh\nsource /workspace/.env\necho \"$MY_SKILL_KEY\""}
        ])

      {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

      # Simulate the preflight slash path directly.
      text =
        Magus.Agents.Plugins.Support.Preflight.apply_slash_skill(
          "/slash-skill go",
          conversation.id,
          user
        )

      assert text == "go"

      # Approval row recorded with the slash source.
      {:ok, approvals} =
        Magus.Skills.list_conversation_approvals(conversation.id, actor: user)

      assert Enum.any?(approvals, &(&1.skill_id == skill.id and &1.source == :slash_command))

      # Materialized + declared secret present in /workspace/.env.
      assert {:ok, %{content: env}} =
               Magus.Sandbox.Orchestrator.read_file(conversation.id, "/workspace/.env", user_id: user.id)

      assert env =~ "MY_SKILL_KEY"
      assert env =~ "sk-live-42"
    end
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run it (with creds)**

Run: `bin/test-e2e-live test/e2e_live/skills_slash_secrets_test.exs --include sandbox`
Expected: 1 test, 0 failures (or skipped if no sandbox creds; confirm it does NOT error).

- [ ] **Step 3: Commit**

```bash
git add test/e2e_live/skills_slash_secrets_test.exs
git commit -m "test(skills): live E2E for slash trigger + declared-secret injection"
```

---

## Task 12: Full-suite gate + RPC regen verification

**Files:** none (verification task)

- [ ] **Step 1: Compile with warnings as errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Backend blast radius**

Run: `mix test test/magus/skills test/magus/chat test/magus/agents`
Expected: PASS (note the shared-DB pre-existing failures documented in memory; scope assertions to seeded rows, do not introduce empty-table assumptions).

- [ ] **Step 3: Frontend**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-slash.spec.ts tests/skills-approval-card.spec.ts tests/sandbox-secrets.spec.ts`
Expected: PASS.

- [ ] **Step 4: Confirm generated RPC is committed and current**

Run: `git status --short frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts`
Expected: clean (already committed in Tasks 8/10). If dirty, regenerate off-server and commit.

- [ ] **Step 5: Commit (only if regen produced changes)**

```bash
git add frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "chore(skills): regenerate RPC types for phase 2a"
```

---

## Notes for the executor

- **Task ordering**: Tasks 1 and 3 are coupled (Task 1's Loader calls `record_conversation_approval` and `approved?/2`). Implement them in one branch; if a reviewer gates Task 1 alone, note the forward reference (documented in Task 1 Step 3). Task 4 (drop the array) must come after Task 3 (join row exists) and its backfill migration must be ordered before the drop migration.
- **Migrations**: never `mix ash.reset`. Each resource task runs `mix ash.codegen <name>` then `mix ash.migrate`. Confirm generated migration ordering by timestamp; the backfill (Task 4) is hand-authored and must sort before the drop.
- **Shared-DB test caveat** (from project memory): the dev/test DB carries committed leaked rows; scope new assertions to rows you seed, never assert empty tables.
- **This plan is SPA-only**: do not touch the classic workbench slash rendering.
