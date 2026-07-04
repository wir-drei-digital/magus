# Memory and Profile Settings View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new "Memory" settings section in the SPA that lets a user view their user-scope memories and distilled profile, delete individual memories, reset the profile, and globally enable/disable memory and the profile, with a per-workspace view filter.

**Architecture:** Backend adds a per-user `profile_enabled` setting (replacing the `MAGUS_MEMORY_PROFILE` env flag), gates extraction on `global_memory_enabled`, and exposes the needed memory/profile read + delete/reset actions over Ash RPC (ash_typescript). Frontend adds one settings route that consumes those RPC actions through thin `api.ts` wrappers, mirroring the existing settings pages.

**Tech Stack:** Elixir/Ash 3.x + AshPostgres + AshTypescript.Rpc; Svelte 5 (runes) SPA with bits-ui + custom CRUD components, Tailwind 4; ash_typescript codegen.

## Global Constraints

- Work ONLY in the worktree `/Users/daniel/Development/magus/.claude/worktrees/memory-hardening` (branch `worktree-memory-hardening`). Use worktree-absolute paths; never `cd` to the main checkout.
- NEVER run `mix ash.reset`. Schema changes go through `mix ash.codegen <name>` + `mix ash.migrate`.
- Before any commit that changes Elixir: `MIX_ENV=test mix compile --warnings-as-errors` must be clean.
- After any backend RPC/action/attribute change consumed by the SPA: run `mix ash_typescript.codegen` and commit the regenerated `frontend/src/lib/ash/ash_rpc.ts` + `frontend/src/lib/ash/ash_types.ts`.
- No em dashes in prose or comments (use colons, commas, periods).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Scope commits explicitly: `git commit -m "..." -- <paths>`.
- Delete = soft-delete (`is_active = false`); toggling a feature off is non-destructive (content stays inert until deleted/reset).
- Frontend tests: assert on `data-testid` hooks and counts, not on visible copy/CSS/URLs. Mirror the framework setup of the nearest existing settings-page test.
- If a pre-existing `magus_test` missing-column error appears (known environmental drift), repair additively with `ALTER TABLE ... ADD COLUMN IF NOT EXISTS ...`; never drop/reset. Report it as a concern.

## File structure

Backend:
- `lib/magus/accounts/user.ex`: add `profile_enabled` attribute + `update_profile_setting` action + policy.
- `lib/magus/accounts/accounts.ex`: expose `update_global_memory_setting` + `update_profile_setting` over RPC.
- `lib/magus/agents/config.ex`: `profile_enabled?/1` (per user id), remove env flag.
- `lib/magus/agents/actions/consolidate_memories.ex`, `lib/magus/agents/actions/build_memory_context.ex`: pass `user_id` to `profile_enabled?`.
- `lib/magus/chat/conversation/changes/extract_turn_memories.ex`: skip extraction when the owner disabled memory.
- `lib/magus/memory/memory.ex`: add `AshTypescript.Rpc` + a `typescript_rpc` block.
- `lib/magus/memory/memory_resource.ex`, `lib/magus/memory/user_profile.ex`: add `AshTypescript.Resource`; UserProfile gets a `clear` action.

Frontend:
- `frontend/src/lib/components/shell/settings-nav.svelte`, `frontend/src/routes/settings/+layout.svelte`: register the section.
- `frontend/src/routes/settings/memory/+page.svelte`: the page.
- `frontend/src/lib/ash/api.ts`: wrappers.

---

### Task 1: User `profile_enabled` setting + RPC exposure of both memory settings

**Files:**
- Modify: `lib/magus/accounts/user.ex` (attribute near line 1190; action near line 387; policy near line 1024)
- Modify: `lib/magus/accounts/accounts.ex` (typescript_rpc block, lines 9-28)
- Test: `test/magus/accounts/user_memory_settings_test.exs` (new)

**Interfaces:**
- Produces: `User.profile_enabled :: boolean` (default false); update action `:update_profile_setting` (accept `[:profile_enabled]`, policy `id == actor(:id)`); RPC actions `update_global_memory_setting` and `update_profile_setting` (used by Task 5's `api.ts`).

- [ ] **Step 1: Write the failing test**

Create `test/magus/accounts/user_memory_settings_test.exs`:

```elixir
defmodule Magus.Accounts.UserMemorySettingsTest do
  use Magus.ResourceCase, async: true

  test "profile_enabled defaults to false and the owner can toggle it" do
    user = generate(user())
    assert user.profile_enabled == false

    {:ok, updated} =
      user
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true}, actor: user)
      |> Ash.update()

    assert updated.profile_enabled == true
  end

  test "a different user cannot change someone else's profile_enabled" do
    owner = generate(user())
    other = generate(user())

    assert {:error, _} =
             owner
             |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true}, actor: other)
             |> Ash.update()
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/accounts/user_memory_settings_test.exs`
Expected: FAIL (no `profile_enabled` attribute / no `:update_profile_setting` action).

- [ ] **Step 3: Add the attribute**

In `lib/magus/accounts/user.ex`, directly after the `global_memory_enabled` attribute block (ends ~line 1190), add:

```elixir
    attribute :profile_enabled, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether the distilled Hermes-style profile is used for this user"
    end
```

- [ ] **Step 4: Add the update action**

After the `update :update_global_memory_setting do ... end` action (ends ~line 387), add:

```elixir
    update :update_profile_setting do
      description "Enable or disable the distilled user profile"
      accept [:profile_enabled]
    end
```

- [ ] **Step 5: Add the policy**

After the `policy action(:update_global_memory_setting)` block (~line 1024), add:

```elixir
    policy action(:update_profile_setting) do
      authorize_if expr(id == ^actor(:id))
    end
```

- [ ] **Step 6: Expose both settings over RPC**

In `lib/magus/accounts/accounts.ex`, inside `typescript_rpc do resource Magus.Accounts.User do ... end`, add under the "Settings" comments:

```elixir
    rpc_action :update_global_memory_setting, :update_global_memory_setting
    rpc_action :update_profile_setting, :update_profile_setting
```

- [ ] **Step 7: Generate the migration**

Run:
```bash
set -a && source .env && set +a
MIX_ENV=test mix ash.codegen add_user_profile_enabled
MIX_ENV=test mix ash.migrate
```
Inspect the generated migration: it must ONLY add the `profile_enabled` boolean column (default false) to `users`. If unrelated drift (e.g. cloud-only tables) appears, revert those with `git checkout --` and report it; do not commit drift.

- [ ] **Step 8: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/accounts/user_memory_settings_test.exs`
Expected: PASS.

- [ ] **Step 9: Regenerate TS + compile check + commit**

```bash
set -a && source .env && set +a
mix ash_typescript.codegen
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/accounts/user.ex lib/magus/accounts/accounts.ex test/magus/accounts/user_memory_settings_test.exs priv/repo/migrations priv/resource_snapshots frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "feat(memory): per-user profile_enabled setting + RPC for both memory settings" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- lib/magus/accounts/user.ex lib/magus/accounts/accounts.ex test/magus/accounts/user_memory_settings_test.exs priv/repo/migrations priv/resource_snapshots frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
```

---

### Task 2: Per-user profile gating (remove the env flag)

**Files:**
- Modify: `lib/magus/agents/config.ex` (`profile_enabled?`, lines 39-46)
- Modify: `lib/magus/agents/actions/consolidate_memories.ex` (line 165)
- Modify: `lib/magus/agents/actions/build_memory_context.ex` (line 98)
- Modify: `test/magus/agents/actions/consolidate_memories_profile_test.exs` (setup, lines 22-26)
- Modify: `test/magus/agents/actions/build_memory_context_test.exs` (profile-injection setup, lines 39-44)
- Test: `test/magus/agents/config_profile_enabled_test.exs` (new)

**Interfaces:**
- Consumes: `User.profile_enabled` (Task 1).
- Produces: `Magus.Agents.Config.profile_enabled?(user_id :: String.t()) :: boolean` (queries the user's setting). The old zero-arity `profile_enabled?/0` and `MAGUS_MEMORY_PROFILE` are removed.

- [ ] **Step 1: Write the failing test**

Create `test/magus/agents/config_profile_enabled_test.exs`:

```elixir
defmodule Magus.Agents.ConfigProfileEnabledTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Config

  test "profile_enabled?/1 reflects the user's setting" do
    off = generate(user())
    assert Config.profile_enabled?(to_string(off.id)) == false

    on =
      generate(user())
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true}, authorize?: false)
      |> Ash.update!()

    assert Config.profile_enabled?(to_string(on.id)) == true
  end

  test "profile_enabled?/1 is false for an unknown user id" do
    assert Config.profile_enabled?(Ecto.UUID.generate()) == false
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/agents/config_profile_enabled_test.exs`
Expected: FAIL (`profile_enabled?/1` undefined).

- [ ] **Step 3: Rewrite the Config function**

In `lib/magus/agents/config.ex`, replace the `profile_enabled?/0` function (lines 39-46) with:

```elixir
  @doc """
  Whether the distilled user profile layer is enabled for the given user.
  Per-user opt-in (default false); there is no global env flag.
  """
  def profile_enabled?(user_id) when is_binary(user_id) do
    require Ash.Query

    Magus.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:profile_enabled])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{profile_enabled: true}} -> true
      _ -> false
    end
  end

  def profile_enabled?(_), do: false
```

- [ ] **Step 4: Update the ConsolidateMemories call site**

In `lib/magus/agents/actions/consolidate_memories.ex`, change the gate (line 165) from `if Magus.Agents.Config.profile_enabled?() do` to:

```elixir
      if Magus.Agents.Config.profile_enabled?(to_string(user_id)) do
```

- [ ] **Step 5: Update the BuildMemoryContext call site**

In `lib/magus/agents/actions/build_memory_context.ex`, change line 98 from `if global_enabled and Magus.Agents.Config.profile_enabled?() do` to:

```elixir
      if global_enabled and Magus.Agents.Config.profile_enabled?(to_string(user_id)) do
```

- [ ] **Step 6: Convert the two env-flag tests to per-user**

In `test/magus/agents/actions/consolidate_memories_profile_test.exs`, replace the `setup do Application.put_env(...) ... end` (lines 22-26) so the created user has `profile_enabled: true`. Find where the test creates its `user` and add, right after creation:

```elixir
    user =
      user
      |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true}, authorize?: false)
      |> Ash.update!()
```

and delete the `Application.put_env`/`on_exit` env-flag setup block.

In `test/magus/agents/actions/build_memory_context_test.exs`, do the same inside the `describe "profile injection"` block: remove the `Application.put_env` setup (lines 39-44) and, in each test in that block, set `profile_enabled: true` on the user it creates via the same `update_profile_setting` call before building context.

- [ ] **Step 7: Run the tests**

Run:
```bash
set -a && source .env && set +a
MIX_ENV=test mix test test/magus/agents/config_profile_enabled_test.exs test/magus/agents/actions/consolidate_memories_profile_test.exs test/magus/agents/actions/build_memory_context_test.exs
```
Expected: PASS.

- [ ] **Step 8: Compile check + commit**

```bash
set -a && source .env && set +a
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/agents/config.ex lib/magus/agents/actions/consolidate_memories.ex lib/magus/agents/actions/build_memory_context.ex test/magus/agents/config_profile_enabled_test.exs test/magus/agents/actions/consolidate_memories_profile_test.exs test/magus/agents/actions/build_memory_context_test.exs
git commit -m "feat(memory): gate the profile on per-user profile_enabled, remove MAGUS_MEMORY_PROFILE env flag" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- lib/magus/agents/config.ex lib/magus/agents/actions/consolidate_memories.ex lib/magus/agents/actions/build_memory_context.ex test/magus/agents/config_profile_enabled_test.exs test/magus/agents/actions/consolidate_memories_profile_test.exs test/magus/agents/actions/build_memory_context_test.exs
```

---

### Task 3: Disable-memory also stops extraction

**Files:**
- Modify: `lib/magus/chat/conversation/changes/extract_turn_memories.ex` (`run_extraction/1`)
- Test: `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs` (extend)

**Interfaces:**
- Consumes: `User.global_memory_enabled` (existing).
- Produces: extraction returns `:ok` without extracting when the conversation owner has `global_memory_enabled == false`.

**Note on injection:** memory *injection* is already gated by `global_memory_enabled`: `BuildMemoryContext.build/…` receives a `global_enabled` param derived from the user's setting, and skips global memories when false. This task only adds the missing *extraction* gate. As part of Step 3, grep the caller of `BuildMemoryContext.build` (search `global_enabled` and `global_memory_enabled` under `lib/magus/agents/`) and confirm `global_enabled` flows from `user.global_memory_enabled`; if it does not, flag it as an out-of-scope gap rather than expanding this task.

- [ ] **Step 1: Write the failing test**

Append to `test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs` a test that a memory-disabled owner's turn is not extracted. Use the existing `seed_turn!` / `run_extract_action` helpers in that file:

```elixir
  test "extraction is skipped when the conversation owner has memory disabled" do
    user =
      generate(user())
      |> Ash.Changeset.for_update(:update_global_memory_setting, %{global_memory_enabled: false},
        authorize?: false
      )
      |> Ash.update!()

    conv = generate(conversation(actor: user))

    seed_turn!(
      conv,
      String.duplicate("I strongly prefer tabs over spaces in every project. ", 3),
      String.duplicate("Understood, tabs it is going forward for all your code. ", 3)
    )

    # No LLM mock expectation: extraction must not call the LLM at all.
    assert {:ok, _} = run_extract_action(conv)
    assert {:ok, []} = Magus.Memory.list_memories_for_conversation(conv.id, authorize?: false)
  end
```

(If the exact list function name differs, use the domain code interface that reads local memories for a conversation; confirm via `lib/magus/memory/memory.ex`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`
Expected: FAIL (extraction runs and either errors on the missing mock or creates a memory).

- [ ] **Step 3: Add the gate to `run_extraction/1`**

In `lib/magus/chat/conversation/changes/extract_turn_memories.ex`, at the very start of `run_extraction/1` (before `turns = load_turns_since(conversation)`), add:

```elixir
  defp run_extraction(conversation) do
    if memory_disabled?(conversation) do
      :ok
    else
      do_run_extraction(conversation)
    end
  end

  defp memory_disabled?(conversation) do
    require Ash.Query

    Magus.Accounts.User
    |> Ash.Query.filter(id == ^conversation.user_id)
    |> Ash.Query.select([:global_memory_enabled])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{global_memory_enabled: false}} -> true
      _ -> false
    end
  end

  defp do_run_extraction(conversation) do
```

Rename the existing `run_extraction/1` body to `do_run_extraction/1` (the body starting `turns = load_turns_since(conversation)` down through its `cond` becomes `do_run_extraction/1`).

- [ ] **Step 4: Run the tests to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs`
Expected: PASS (all tests, including the existing ones).

- [ ] **Step 5: Compile check + commit**

```bash
set -a && source .env && set +a
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/chat/conversation/changes/extract_turn_memories.ex test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs
git commit -m "feat(memory): stop turn extraction when the user disabled memory" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- lib/magus/chat/conversation/changes/extract_turn_memories.ex test/magus/chat/conversation/changes/extract_turn_memories_change_test.exs
```

---

### Task 4: Expose memory + profile over RPC (+ profile `clear`)

**Files:**
- Modify: `lib/magus/memory/memory.ex` (add `AshTypescript.Rpc` + `typescript_rpc` block)
- Modify: `lib/magus/memory/memory_resource.ex` (add `AshTypescript.Resource` extension)
- Modify: `lib/magus/memory/user_profile.ex` (add `AshTypescript.Resource` extension + `clear` action)
- Test: `test/magus/memory/user_profile_clear_test.exs` (new); `test/magus/memory/memory_user_rpc_policy_test.exs` (new)

**Interfaces:**
- Consumes: existing `user_for_user`, `deactivate` (Memory), `for_bucket` (UserProfile).
- Produces: RPC actions the SPA calls in Task 5: list user memories, deactivate a memory, read the profile for a bucket, clear the profile. Plus `UserProfile.:clear` (empties the document, snapshots a version).

- [ ] **Step 1: Write the failing tests**

Create `test/magus/memory/user_profile_clear_test.exs`:

```elixir
defmodule Magus.Memory.UserProfileClearTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent
  @ai %AiAgent{}

  test "clear empties the document and snapshots a version; owner authorized" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: "## Focus\nX"}, actor: @ai)

    {:ok, cleared} =
      profile
      |> Ash.Changeset.for_update(:clear, %{}, actor: user)
      |> Ash.update()

    assert cleared.document == ""
    assert cleared.token_estimate == 0
    {:ok, versions} = Magus.Memory.list_profile_versions(profile.id, actor: @ai)
    assert length(versions) >= 1
  end

  test "a different user cannot clear someone else's profile" do
    owner = generate(user())
    other = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(owner.id, nil, %{document: "secret"}, actor: @ai)

    assert {:error, _} =
             profile |> Ash.Changeset.for_update(:clear, %{}, actor: other) |> Ash.update()
  end
end
```

Create `test/magus/memory/memory_user_rpc_policy_test.exs`:

```elixir
defmodule Magus.Memory.MemoryUserRpcPolicyTest do
  use Magus.ResourceCase, async: true

  test "a user reads only their own user-scope memories via user_for_user" do
    user = generate(user())
    other = generate(user())

    {:ok, _} =
      Magus.Memory.create_user_memory(user.id, nil, "Mine", %{content: %{}, summary: "mine"},
        actor: %Magus.Agents.Support.AiAgent{}
      )

    {:ok, mine} =
      Magus.Memory.Memory
      |> Ash.Query.for_read(:user_for_user, %{workspace_id: nil}, actor: user)
      |> Ash.read()

    assert Enum.all?(mine, &(&1.user_id == user.id))

    {:ok, theirs} =
      Magus.Memory.Memory
      |> Ash.Query.for_read(:user_for_user, %{workspace_id: nil}, actor: other)
      |> Ash.read()

    refute Enum.any?(theirs, &(&1.user_id == user.id))
  end

  test "a user can deactivate their own memory but not another's" do
    user = generate(user())
    other = generate(user())

    {:ok, mem} =
      Magus.Memory.create_user_memory(user.id, nil, "Mine", %{content: %{}, summary: "mine"},
        actor: %Magus.Agents.Support.AiAgent{}
      )

    assert {:error, _} = mem |> Ash.Changeset.for_update(:deactivate, %{}, actor: other) |> Ash.update()
    assert {:ok, deac} = mem |> Ash.Changeset.for_update(:deactivate, %{}, actor: user) |> Ash.update()
    assert deac.is_active == false
  end
end
```

(Add `require Ash.Query` at the top of the policy test module.)

- [ ] **Step 2: Run to verify failure**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/memory/user_profile_clear_test.exs test/magus/memory/memory_user_rpc_policy_test.exs`
Expected: the clear test FAILS (`:clear` undefined); the policy test may already pass for `user_for_user`/`deactivate` (those actions exist) but keep it as a regression guard.

- [ ] **Step 3: Add the `clear` action to UserProfile**

In `lib/magus/memory/user_profile.ex`, after the `set_document` action (ends ~line 73), add:

```elixir
    update :clear do
      description "Reset the profile document to empty (keeps the row + version history)"
      accept []
      require_atomic? false

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:document, "")
        |> Ash.Changeset.force_change_attribute(:token_estimate, 0)
        |> Ash.Changeset.force_change_attribute(:pending_notes, [])
        |> Ash.Changeset.force_change_attribute(:last_distilled_at, DateTime.utc_now())
      end

      change Magus.Memory.UserProfile.Changes.CreateVersion
    end
```

- [ ] **Step 4: Add the AshTypescript.Resource extension to both resources**

In `lib/magus/memory/memory_resource.ex`, add `AshTypescript.Resource` to the `use Ash.Resource, ... extensions: [...]` list (find the existing `use Ash.Resource` and add the extension to its `extensions:`; if there is no `extensions:` key, add `extensions: [AshTypescript.Resource]`).

In `lib/magus/memory/user_profile.ex`, do the same on its `use Ash.Resource`.

- [ ] **Step 5: Add the RPC block to the Memory domain**

In `lib/magus/memory/memory.ex`, change `use Ash.Domain, otp_app: :magus` to `use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]`, and add (above the `resources do` block):

```elixir
  typescript_rpc do
    resource Magus.Memory.Memory do
      rpc_action :list_user_memories, :user_for_user
      rpc_action :deactivate_user_memory, :deactivate
    end

    resource Magus.Memory.UserProfile do
      rpc_action :get_user_profile, :for_bucket
      rpc_action :clear_user_profile, :clear
    end
  end
```

- [ ] **Step 6: Run the tests to verify pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/memory/user_profile_clear_test.exs test/magus/memory/memory_user_rpc_policy_test.exs`
Expected: PASS.

- [ ] **Step 7: Regenerate TS + compile + commit**

```bash
set -a && source .env && set +a
mix ash_typescript.codegen
MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus/memory/memory.ex lib/magus/memory/memory_resource.ex lib/magus/memory/user_profile.ex test/magus/memory/user_profile_clear_test.exs test/magus/memory/memory_user_rpc_policy_test.exs priv/resource_snapshots frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "feat(memory): expose user memory list/deactivate + profile read/clear over RPC" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- lib/magus/memory/memory.ex lib/magus/memory/memory_resource.ex lib/magus/memory/user_profile.ex test/magus/memory/user_profile_clear_test.exs test/magus/memory/memory_user_rpc_policy_test.exs priv/resource_snapshots frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
```

---

### Task 5: SPA api.ts wrappers

**Files:**
- Modify: `frontend/src/lib/ash/api.ts`

**Interfaces:**
- Consumes: generated `rpc.updateGlobalMemorySetting`, `rpc.updateProfileSetting`, `rpc.listUserMemories`, `rpc.deactivateUserMemory`, `rpc.getUserProfile`, `rpc.clearUserProfile` (names per Task 1/4 rpc_action names; verify exact casing in the regenerated `ash_rpc.ts`).
- Produces (in `api.ts`): `updateMemorySetting(userId, enabled)`, `updateProfileSetting(userId, enabled)`, `listUserMemories(workspaceId | null)`, `deactivateUserMemory(memoryId)`, `getUserProfile(userId, workspaceId | null)`, `clearUserProfile(profileId)`, plus a `UserMemory` and `UserProfileDoc` type. Consumed by Tasks 6-8.

**Testing note (whole frontend):** the SPA unit-tests pure logic with vitest (`npm run test:unit`) and does NOT use component/render tests. So these `api.ts` wrappers (thin glue over generated RPC) are verified by the type checker (`npm run check`, which runs `svelte-check`), which fails if a wrapper references a non-existent generated `rpc.*` function or a wrong field/input shape. The only frontend vitest test in this plan is the extracted `bucketOptions` helper in Task 7. Page-level behavior is verified by the backend tests (Tasks 1-4 cover the real policy/gating/clear logic) plus manual check of the running SPA.

- [ ] **Step 1: (no separate unit test)**

Per the testing note above, the gate for this task is `npm run check` in Step 3. Do not add a component test.

- [ ] **Step 2: Add the wrappers**

In `frontend/src/lib/ash/api.ts`, near the other user-settings wrappers, add (adjust `rpc.<name>` and field names to match the regenerated client exactly):

```typescript
export type UserMemory = {
  id: string;
  name: string;
  summary: string | null;
  kind: string | null;
  updatedAt: string | null;
};

export type UserProfileDoc = {
  id: string;
  document: string;
  tokenEstimate: number;
  lastDistilledAt: string | null;
};

export function updateMemorySetting(userId: string, enabled: boolean): Promise<RpcResult<CurrentUser>> {
  return run((opts) =>
    rpc.updateGlobalMemorySetting({
      identity: userId,
      input: { globalMemoryEnabled: enabled },
      fields: USER_SETTINGS_FIELDS,
      ...opts
    })
  );
}

export function updateProfileSetting(userId: string, enabled: boolean): Promise<RpcResult<CurrentUser>> {
  return run((opts) =>
    rpc.updateProfileSetting({
      identity: userId,
      input: { profileEnabled: enabled },
      fields: USER_SETTINGS_FIELDS,
      ...opts
    })
  );
}

const USER_MEMORY_FIELDS = ['id', 'name', 'summary', 'kind', 'updatedAt'] as const;

export async function listUserMemories(workspaceId: string | null): Promise<RpcResult<UserMemory[]>> {
  const result = await run<Array<Record<string, unknown>> | null>((opts) =>
    rpc.listUserMemories({ input: { workspaceId }, fields: USER_MEMORY_FIELDS, ...opts })
  );
  if (!result.success) return result;
  return { success: true, data: (result.data ?? []) as UserMemory[] };
}

export async function deactivateUserMemory(memoryId: string): Promise<RpcResult<{ id: string }>> {
  const result = await run<Record<string, unknown> | null>((opts) =>
    rpc.deactivateUserMemory({ identity: memoryId, input: {}, fields: ['id'], ...opts })
  );
  if (!result.success) return result;
  return { success: true, data: { id: String((result.data ?? {}).id ?? memoryId) } };
}

const USER_PROFILE_FIELDS = ['id', 'document', 'tokenEstimate', 'lastDistilledAt'] as const;

export async function getUserProfile(userId: string, workspaceId: string | null): Promise<RpcResult<UserProfileDoc | null>> {
  const result = await run<Record<string, unknown> | null>((opts) =>
    rpc.getUserProfile({ input: { userId, workspaceId }, fields: USER_PROFILE_FIELDS, ...opts })
  );
  if (!result.success) return result;
  return { success: true, data: (result.data ?? null) as UserProfileDoc | null };
}

export async function clearUserProfile(profileId: string): Promise<RpcResult<{ id: string }>> {
  const result = await run<Record<string, unknown> | null>((opts) =>
    rpc.clearUserProfile({ identity: profileId, input: {}, fields: ['id'], ...opts })
  );
  if (!result.success) return result;
  return { success: true, data: { id: String((result.data ?? {}).id ?? profileId) } };
}
```

Note: `deactivate`/`clear` are updates on a specific row, so they take `identity: <rowId>`. `list_user_memories`/`get_user_profile` are reads that take arguments in `input`. Confirm the `identity` vs `input` shape for each against the regenerated `ash_rpc.ts` (reads with `get?`/args differ from updates).

- [ ] **Step 3: Type + lint check**

Run: `cd frontend && npm run check` (or the repo's svelte-check/tsc script; discover via `frontend/package.json` scripts).
Expected: no type errors referencing the new wrappers.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/ash/api.ts
git commit -m "feat(memory): api.ts wrappers for memory/profile settings, list, delete, reset" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- frontend/src/lib/ash/api.ts
```

---

### Task 6: Settings section + global toggles

**Files:**
- Modify: `frontend/src/lib/components/shell/settings-nav.svelte` (sections array + icon import)
- Modify: `frontend/src/routes/settings/+layout.svelte` (SECTION_LABELS)
- Modify: `frontend/src/lib/ash/api.ts` (add the two boolean fields to CurrentUser)
- Create: `frontend/src/routes/settings/memory/+page.svelte`

**Interfaces:**
- Consumes: `updateMemorySetting`, `updateProfileSetting` (Task 5); `session.user` (id, `globalMemoryEnabled`, `profileEnabled`).
- Produces: the `settings/memory` route with two toggles (`data-testid="memory-toggle"`, `data-testid="profile-toggle"`).

Verification for this task is `npm run check` (svelte-check); there is no component render test (see Task 5's testing note).

- [ ] **Step 1: Expose the two booleans on CurrentUser**

In `frontend/src/lib/ash/api.ts`: add `'globalMemoryEnabled'` and `'profileEnabled'` to the `USER_SETTINGS_FIELDS` array, and add `globalMemoryEnabled: boolean;` and `profileEnabled: boolean;` to the `CurrentUser` type. (These come from the User RPC fields exposed in Task 1.)

- [ ] **Step 2: Register the section**

In `frontend/src/lib/components/shell/settings-nav.svelte`: add `Brain` to the `@lucide/svelte` import, and add `{ id: 'memory', label: 'Memory', icon: Brain }` to the `sections` array (place it after `models`).

In `frontend/src/routes/settings/+layout.svelte`: add `memory: 'Memory',` to `SECTION_LABELS`.

- [ ] **Step 3: Create the page with toggles**

Create `frontend/src/routes/settings/memory/+page.svelte`:

```svelte
<script lang="ts">
  import { Section as SettingsSection, ToggleSwitch } from '$lib/components/crud';
  import { session } from '$lib/stores/session.svelte';
  import { updateMemorySetting, updateProfileSetting } from '$lib/ash/api';

  let memoryEnabled = $state(session.user?.globalMemoryEnabled ?? true);
  let profileEnabled = $state(session.user?.profileEnabled ?? false);

  async function toggleMemory(next: boolean) {
    const prev = memoryEnabled;
    memoryEnabled = next;
    const userId = session.user?.id;
    if (!userId) return;
    const result = await updateMemorySetting(userId, next);
    if (!result.success) memoryEnabled = prev;
    else session.user = result.data;
  }

  async function toggleProfile(next: boolean) {
    const prev = profileEnabled;
    profileEnabled = next;
    const userId = session.user?.id;
    if (!userId) return;
    const result = await updateProfileSetting(userId, next);
    if (!result.success) profileEnabled = prev;
    else session.user = result.data;
  }
</script>

<div class="space-y-6">
  <SettingsSection title="Memory" description="Let Magus remember facts about you across conversations.">
    <ToggleSwitch
      checked={memoryEnabled}
      label="Enable memory"
      testid="memory-toggle"
      onchange={(next) => void toggleMemory(next)}
    />
  </SettingsSection>

  <SettingsSection title="Profile" description="A short living summary distilled from your memories.">
    <ToggleSwitch
      checked={profileEnabled}
      disabled={!memoryEnabled}
      label="Enable profile"
      testid="profile-toggle"
      onchange={(next) => void toggleProfile(next)}
    />
    {#if !memoryEnabled}
      <p class="mt-1 text-xs text-muted-foreground" data-testid="profile-disabled-note">
        Turn memory on to use the profile.
      </p>
    {/if}
  </SettingsSection>
</div>
```

(Confirm the `$lib/components/crud` barrel exports `Section` and `ToggleSwitch`; if not, import from their exact files as the extraction showed.)

- [ ] **Step 4: Verify with svelte-check**

Run: `cd frontend && npm run check`
Expected: no type errors (svelte-check validates the toggles, the api wrappers, and the new CurrentUser fields).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/shell/settings-nav.svelte frontend/src/routes/settings/+layout.svelte frontend/src/routes/settings/memory/+page.svelte frontend/src/lib/ash/api.ts
git commit -m "feat(memory): memory settings section with global memory/profile toggles" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- frontend/src/lib/components/shell/settings-nav.svelte frontend/src/routes/settings/+layout.svelte frontend/src/routes/settings/memory/+page.svelte frontend/src/lib/ash/api.ts
```

---

### Task 7: Workspace filter + memory list + delete

**Files:**
- Create: `frontend/src/lib/settings/memory-buckets.ts` (pure helper)
- Create: `frontend/src/lib/settings/memory-buckets.test.ts` (vitest)
- Modify: `frontend/src/routes/settings/memory/+page.svelte`

**Interfaces:**
- Consumes: `listUserMemories`, `deactivateUserMemory` (Task 5); the workspaces list the way `workspace-switcher.svelte` reads it (the `workbench` store's `workspaces`); `confirmAction` (the SPA's confirm dialog helper used in `frontend/src/routes/agents/[agentId]/+page.svelte`).
- Produces: `bucketOptions(workspaces, currentWorkspaceId) :: {value: string|null, label: string}[]` (pure, unit-tested); a local `selectedBucketId` filter (default `session.user?.currentWorkspaceId ?? null`) driving a memory list with per-row delete. Testids: `memory-bucket-filter`, `user-memories`, `memory-delete-<id>`. Page wiring is verified by svelte-check (see Task 5's testing note); only the pure helper gets a vitest test.

- [ ] **Step 1: Write the failing helper test**

Create `frontend/src/lib/settings/memory-buckets.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import { bucketOptions } from './memory-buckets';

describe('bucketOptions', () => {
  it('always lists Personal first with a null value', () => {
    expect(bucketOptions([], null)[0]).toEqual({ value: null, label: 'Personal' });
  });

  it('appends one option per workspace in order', () => {
    expect(bucketOptions([{ id: 'a', name: 'Alpha' }, { id: 'b', name: 'Beta' }], null)).toEqual([
      { value: null, label: 'Personal' },
      { value: 'a', label: 'Alpha' },
      { value: 'b', label: 'Beta' }
    ]);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd frontend && npm run test:unit -- src/lib/settings/memory-buckets.test.ts`
Expected: FAIL (module not found).

- [ ] **Step 3: Implement the helper**

Create `frontend/src/lib/settings/memory-buckets.ts`:

```typescript
export type BucketOption = { value: string | null; label: string };

export function bucketOptions(
  workspaces: Array<{ id: string; name: string }>,
  _currentWorkspaceId: string | null
): BucketOption[] {
  return [
    { value: null, label: 'Personal' },
    ...workspaces.map((w) => ({ value: w.id, label: w.name }))
  ];
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && npm run test:unit -- src/lib/settings/memory-buckets.test.ts`
Expected: PASS.

- [ ] **Step 5: Wire the filter + list + delete into the page**

Extend `+page.svelte`: import `listUserMemories`, `deactivateUserMemory`, the `UserMemory` type, `bucketOptions`, the confirm helper (find its import in `frontend/src/routes/agents/[agentId]/+page.svelte`), and the workspaces source used by `workspace-switcher.svelte`. Add:

```svelte
  import { listUserMemories, deactivateUserMemory, type UserMemory } from '$lib/ash/api';
  // plus: confirm helper + workspaces store, imported as in the agents page / workspace-switcher

  let selectedBucketId = $state<string | null>(session.user?.currentWorkspaceId ?? null);
  let memories = $state<UserMemory[]>([]);
  let memLoading = $state(true);

  async function loadMemories() {
    memLoading = true;
    const result = await listUserMemories(selectedBucketId);
    if (result.success) memories = result.data;
    memLoading = false;
  }

  $effect(() => {
    // refetch whenever the bucket changes
    selectedBucketId;
    void loadMemories();
  });

  async function removeMemory(m: UserMemory) {
    const ok = await confirmAction({
      title: 'Delete this memory?',
      description: `"${m.name}" will be removed from your memory.`,
      confirmLabel: 'Delete'
    });
    if (!ok) return;
    const result = await deactivateUserMemory(m.id);
    if (result.success) memories = memories.filter((x) => x.id !== m.id);
  }
```

Build the filter options with the helper: `const options = $derived(bucketOptions(workbench.workspaces, session.user?.currentWorkspaceId ?? null));` (import `workbench` the way `workspace-switcher.svelte` does). Add a bucket `<select data-testid="memory-bucket-filter" bind:value={selectedBucketId}>` rendering `{#each options as o}<option value={o.value}>{o.label}</option>{/each}`, and a memories list section:

```svelte
  <SettingsSection title="Your memories" description="Facts Magus has stored about you.">
    <!-- bucket filter select here, testid="memory-bucket-filter" -->
    {#if memLoading}
      <div class="h-10 animate-pulse rounded-lg bg-muted/60"></div>
    {:else if memories.length === 0}
      <p class="text-xs text-muted-foreground" data-testid="user-memories-empty">No memories yet.</p>
    {:else}
      <div class="flex flex-col gap-1.5" data-testid="user-memories">
        {#each memories as m (m.id)}
          <div class="flex items-start justify-between gap-2 rounded-lg bg-secondary/60 px-3 py-2">
            <span class="min-w-0">
              <span class="text-sm font-medium">{m.name}</span>
              {#if m.summary}
                <span class="mt-0.5 block truncate text-xs text-muted-foreground">{m.summary}</span>
              {/if}
            </span>
            <button
              type="button"
              class="text-destructive hover:bg-destructive/10 shrink-0 rounded px-2 py-1 text-xs"
              data-testid={`memory-delete-${m.id}`}
              onclick={() => void removeMemory(m)}
            >
              Delete
            </button>
          </div>
        {/each}
      </div>
    {/if}
  </SettingsSection>
```

- [ ] **Step 6: Verify + commit**

```bash
cd frontend && npm run check && npm run test:unit -- src/lib/settings/memory-buckets.test.ts
cd ..
git add frontend/src/lib/settings/memory-buckets.ts frontend/src/lib/settings/memory-buckets.test.ts frontend/src/routes/settings/memory/+page.svelte
git commit -m "feat(memory): user-memory list with per-workspace filter and delete" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- frontend/src/lib/settings/memory-buckets.ts frontend/src/lib/settings/memory-buckets.test.ts frontend/src/routes/settings/memory/+page.svelte
```

---

### Task 8: Profile card + reset

**Files:**
- Modify: `frontend/src/routes/settings/memory/+page.svelte`

**Interfaces:**
- Consumes: `getUserProfile`, `clearUserProfile` (Task 5); the same `selectedBucketId` (Task 7); `session.user.id`; the confirm helper.
- Produces: a profile card that shows the selected bucket's document and a Reset button. Testids: `profile-card`, `profile-empty`, `profile-reset`. Display glue with no pure logic to extract, so verified by svelte-check (see Task 5's testing note).

- [ ] **Step 1: Add the profile card + reset**

Extend `+page.svelte`:

```svelte
  import { getUserProfile, clearUserProfile, type UserProfileDoc } from '$lib/ash/api';

  let profile = $state<UserProfileDoc | null>(null);
  let profileLoading = $state(true);

  async function loadProfile() {
    profileLoading = true;
    const userId = session.user?.id;
    if (!userId) { profileLoading = false; return; }
    const result = await getUserProfile(userId, selectedBucketId);
    if (result.success) profile = result.data;
    profileLoading = false;
  }

  $effect(() => {
    selectedBucketId;
    void loadProfile();
  });

  async function resetProfile() {
    if (!profile) return;
    const ok = await confirmAction({
      title: 'Reset your profile?',
      description: 'The distilled profile for this workspace will be cleared. It rebuilds from your memories over time.',
      confirmLabel: 'Reset'
    });
    if (!ok) return;
    const result = await clearUserProfile(profile.id);
    if (result.success) profile = { ...profile, document: '', tokenEstimate: 0 };
  }
```

And a section:

```svelte
  <SettingsSection title="Profile" description="The distilled summary for the selected workspace.">
    {#if profileLoading}
      <div class="h-16 animate-pulse rounded-lg bg-muted/60"></div>
    {:else if !profile || profile.document === ''}
      <p class="text-xs text-muted-foreground" data-testid="profile-empty">
        No profile yet. It is distilled from your memories over time.
      </p>
    {:else}
      <div class="space-y-2" data-testid="profile-card">
        <pre class="whitespace-pre-wrap rounded-lg bg-secondary/60 p-3 text-xs">{profile.document}</pre>
        <button
          type="button"
          class="text-destructive hover:bg-destructive/10 rounded px-2 py-1 text-xs"
          data-testid="profile-reset"
          onclick={() => void resetProfile()}
        >
          Reset profile
        </button>
      </div>
    {/if}
  </SettingsSection>
```

Note: this Profile section (the document + reset) is separate from the Profile toggle section from Task 6; keep both. The toggle enables the feature; this card shows/reset the content.

- [ ] **Step 2: Verify with svelte-check**

Run: `cd frontend && npm run check`
Expected: no type errors.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/routes/settings/memory/+page.svelte
git commit -m "feat(memory): profile card with reset in memory settings" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" -- frontend/src/routes/settings/memory/+page.svelte
```

---

### Task 9: Full verification

**Files:** none new.

- [ ] **Step 1: Backend suite for touched areas**

Run:
```bash
set -a && source .env && set +a
MIX_ENV=test mix test test/magus/accounts/ test/magus/agents/ test/magus/memory/ test/magus/chat/conversation/changes/
```
Expected: green (note any pre-existing shared-DB failures separately).

- [ ] **Step 2: Warnings-as-errors + frontend check**

```bash
set -a && source .env && set +a
MIX_ENV=test mix compile --warnings-as-errors
cd frontend && npm run check && npm run test:unit
```
Expected: clean compile; frontend type-check clean; vitest suite (including the new `memory-buckets` test) passes.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A lib test frontend
git commit -m "chore(memory): settings view verification fixups" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
Skip if the tree is clean.
