# User-Managed Skills — Phase 1A: Skill Resource Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `Magus.Skills.Skill` Ash resource as a workspace-scoped, shareable, RPC-exposed resource so users can create, edit, share, and list skills (prompt-only at this stage; bundles, discovery, and execution come in later plans).

**Architecture:** A new `Magus.Skills` domain holds a single `Skill` resource that follows the exact workspace-scoped pattern of `Magus.Library.Prompt`: `workspace_scoped_policies`, `share_to_team`/`unshare_from_team` grant actions, the `is_shared_to_workspace` calculation, and `DestroyResourceGrants` cleanup. The resource is exposed to the SvelteKit SPA via AshTypescript RPC. Bundle/secret columns exist on the schema now but are populated by later plans.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, AshTypescript, ExUnit (`Magus.ResourceCase`).

## Plan sequence (context)

This is plan **1A of the Phase 1 backend**. It produces working, tested software on its own (a CRUD + shareable + RPC-exposed resource). Following plans:
- **1B — Discovery + load dispatch:** per-actor discovery merge (built-in ∪ user skills), `system_prompts` composition, `load_skill` dispatch by `skill_ref`, `tool_builder` per-actor resolution, conversation tracking.
- **1C — Bundles + import + materialization + approval:** non-indexing bundle storage, import pipeline (safe unpack, full `SKILL.md` parser, adapter), `/rpc/skills/import` controller, materializer, first-run approval, secret sourcing, capability gating.
- **Phase 1 SPA plan**, then **Phase 2/3 plans.**

Do not implement 1B/1C work in this plan. Columns this plan adds for later use (`bundle_path`, `file_manifest`, `has_executable_bundle`, `required_secrets`, `runtime_hints`) are inert here.

## Global Constraints

- Call resources through domain code interfaces (`Magus.Skills.create_skill/2`), never `Ash.read/4` directly in app code or tests.
- Always pass a real `actor:` (a `%Magus.Accounts.User{}`). Do not use `authorize?: false` in app code (tests may use it only inside fixtures, mirroring `generators.ex`).
- Wire policies with `Magus.Workspaces.Policies.workspace_scoped_policies/1`. Workspace `:admin` is implicitly owner.
- Schema changes go through `mix ash.codegen --name <name>` then `mix ash.migrate`. NEVER `mix ash.reset` (it wipes data).
- Regenerate the SPA client with `mix ash_typescript.codegen` after any `typescript_rpc` change.
- Resource tests use `use Magus.ResourceCase, async: true` and the `generate(user())` / `Workspaces.create_workspace` fixtures.
- Before committing new Elixir, run `MIX_ENV=test mix compile --warnings-as-errors` (CI compiles with warnings-as-errors; per-edit hooks do not).
- No em dashes in any prose or comments you write (use colons, periods, commas).

**Deviation from spec (noted):** the spec listed a soft-delete `deleted_at`. This plan uses hard `destroy` with `DestroyResourceGrants` cleanup, matching the `Prompt` template, because soft-delete adds no v1 value and complicates policy/uniqueness filters. Revisit if soft-delete becomes a requirement.

---

### Task 1: Register `:skill` in ResourceAccess

**Files:**
- Modify: `lib/magus/workspaces/resource_access.ex` (the `@resource_types` module attribute)
- Test: `test/magus/workspaces/resource_access_test.exs` (create if absent)

**Interfaces:**
- Produces: the `:skill` atom is accepted as a `ResourceAccess` `resource_type`, which every later sharing action and policy depends on.

- [ ] **Step 1: Write the failing test**

Add to `test/magus/workspaces/resource_access_test.exs` (create the file if it does not exist):

```elixir
defmodule Magus.Workspaces.ResourceAccessTest do
  use Magus.ResourceCase, async: true

  test ":skill is an accepted resource_type" do
    assert :skill in Magus.Workspaces.ResourceAccess.resource_types()
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/workspaces/resource_access_test.exs`
Expected: FAIL. Either `resource_types/0` is undefined, or `:skill` is not in the list.

- [ ] **Step 3: Add `:skill` to the resource types and expose a reader**

In `lib/magus/workspaces/resource_access.ex`, find the `@resource_types` attribute and add `:skill`:

```elixir
@resource_types [
  :folder,
  :file,
  :conversation,
  :prompt,
  :custom_agent,
  :brain,
  :knowledge_collection,
  :mcp_server,
  :skill
]
```

If a public reader does not already exist, add one near the top of the module (after the attribute):

```elixir
@doc "The resource types that can be granted access via ResourceAccess."
def resource_types, do: @resource_types
```

(If `@resource_types` is used in an `constraints one_of: @resource_types` on the `resource_type` attribute, no other change is needed: adding the atom widens the constraint.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/workspaces/resource_access_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/workspaces/resource_access.ex test/magus/workspaces/resource_access_test.exs
git commit -m "feat(skills): allow :skill resource_type in ResourceAccess"
```

---

### Task 2: Create the `Skill` resource and `Magus.Skills` domain

**Files:**
- Create: `lib/magus/skills/skills.ex` (domain)
- Create: `lib/magus/skills/skill.ex` (resource)
- Modify: `config/config.exs` (add `Magus.Skills` to `ash_domains`)
- Generate: a migration via `mix ash.codegen --name create_skills`
- Test: `test/magus/skills/skill_test.exs`

**Interfaces:**
- Produces:
  - `Magus.Skills.create_skill(attrs, opts)` → `{:ok, %Skill{}} | {:error, _}` (accepts `name`, `display_name`, `description`, `body`, `requested_tools`, `required_secrets`, `runtime_hints`, `metadata`, `version`, `license`, `compatibility`, `icon`, `color`, `source_format`, `source_url`, `workspace_id`).
  - `Magus.Skills.get_skill(id, opts)` → `{:ok, %Skill{}} | {:error, _}`.
  - `Magus.Skills.update_skill(skill, attrs, opts)` → `{:ok, %Skill{}}`.
  - `Magus.Skills.destroy_skill(skill, opts)` → `:ok | {:ok, _}`.
  - `%Magus.Skills.Skill{}` struct with fields: `id, name, display_name, description, body, requested_tools, required_secrets, runtime_hints, metadata, version, license, compatibility, icon, color, source_format, source_url, has_executable_bundle, bundle_path, bundle_backend, bundle_byte_size, file_manifest, user_id, workspace_id, inserted_at, updated_at`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/skill_test.exs`:

```elixir
defmodule Magus.Skills.SkillTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  describe "create/read as owner" do
    setup do
      owner = generate(user())
      %{owner: owner}
    end

    test "owner creates and reads a personal skill", %{owner: owner} do
      {:ok, skill} =
        Skills.create_skill(
          %{name: "pdf-filler", description: "Fill PDF forms", body: "# PDF\n"},
          actor: owner
        )

      assert skill.name == "pdf-filler"
      assert skill.source_format == :skill_md
      assert skill.has_executable_bundle == false
      assert {:ok, fetched} = Skills.get_skill(skill.id, actor: owner)
      assert fetched.id == skill.id
    end

    test "owner updates the body", %{owner: owner} do
      {:ok, skill} =
        Skills.create_skill(%{name: "note-taker", description: "Notes"}, actor: owner)

      {:ok, updated} = Skills.update_skill(skill, %{body: "# Notes\nUse markdown."}, actor: owner)
      assert updated.body == "# Notes\nUse markdown."
    end

    test "rejects an invalid name", %{owner: owner} do
      assert {:error, %Ash.Error.Invalid{}} =
               Skills.create_skill(%{name: "Bad Name!", description: "x"}, actor: owner)
    end
  end

  describe "ownership isolation" do
    test "a non-owner cannot read a personal skill" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, skill} =
        Skills.create_skill(%{name: "secret-skill", description: "x"}, actor: owner)

      assert {:error, _} = Skills.get_skill(skill.id, actor: stranger)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/skills/skill_test.exs`
Expected: FAIL with a compile error (`Magus.Skills` / `Magus.Skills.Skill` undefined).

- [ ] **Step 3: Create the domain module**

Create `lib/magus/skills/skills.ex`:

```elixir
defmodule Magus.Skills do
  @moduledoc """
  Skills domain: user-managed, workspace-shareable skills. A skill is the
  Anthropic Agent Skills `SKILL.md` format extended as a superset: a markdown
  body plus optional bundled scripts that run in the sandbox (bundles land in
  a later plan). This plan establishes the resource, sharing, and RPC surface.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  @doc "Whether the user-managed skills feature is enabled for this instance."
  def enabled? do
    Application.get_env(:magus, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  resources do
    resource Magus.Skills.Skill do
      define :create_skill, action: :create
      define :get_skill, action: :read, get_by: [:id]
      define :update_skill, action: :update
      define :destroy_skill, action: :destroy
      define :list_skills, action: :read
    end
  end
end
```

- [ ] **Step 4: Create the resource module**

Create `lib/magus/skills/skill.ex`:

```elixir
defmodule Magus.Skills.Skill do
  use Ash.Resource,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "skills"
    repo Magus.Repo
  end

  typescript do
    type_name "Skill"
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      require_atomic? false
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :skill}
    end

    create :create do
      primary? true

      accept [
        :name,
        :display_name,
        :description,
        :body,
        :requested_tools,
        :required_secrets,
        :runtime_hints,
        :metadata,
        :version,
        :license,
        :compatibility,
        :icon,
        :color,
        :source_format,
        :source_url,
        :workspace_id
      ]

      change relate_actor(:user)
    end

    update :update do
      primary? true

      accept [
        :name,
        :display_name,
        :description,
        :body,
        :requested_tools,
        :required_secrets,
        :runtime_hints,
        :metadata,
        :version,
        :license,
        :compatibility,
        :icon,
        :color
      ]
    end
  end

  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(resource_type: :skill)
  end

  validations do
    validate match(:name, ~r/^[a-z0-9-]{1,64}$/) do
      message "must be lowercase letters, numbers, and hyphens, at most 64 characters"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "SKILL.md name: lowercase, numbers, hyphens, max 64 chars"
    end

    attribute :display_name, :string do
      allow_nil? true
      public? true
    end

    attribute :description, :string do
      allow_nil? false
      public? true
      description "One-line description; drives discovery"
    end

    attribute :body, :string do
      allow_nil? true
      public? true
      description "The SKILL.md markdown body (instructions)"
    end

    attribute :requested_tools, {:array, :string} do
      allow_nil? true
      default []
      public? true
      description "Existing Magus tools the skill wants (maps to SKILL.md allowed-tools)"
    end

    attribute :required_secrets, {:array, :map} do
      allow_nil? true
      default []
      public? true
      description "Declarative hints [%{key, description}]; no values stored"
    end

    attribute :runtime_hints, :map do
      allow_nil? true
      default %{}
      description "Optional %{packages: [...], image: ...}"
    end

    attribute :metadata, :map do
      allow_nil? true
      default %{}
      description "Standard SKILL.md metadata passthrough"
    end

    attribute :version, :string do
      allow_nil? true
      public? true
    end

    attribute :license, :string do
      allow_nil? true
      public? true
    end

    attribute :compatibility, :string do
      allow_nil? true
      public? true
    end

    attribute :icon, :string do
      allow_nil? true
      public? true
    end

    attribute :color, :string do
      allow_nil? true
      public? true
    end

    attribute :source_format, :atom do
      constraints one_of: [:skill_md, :agents_md, :goose, :other]
      default :skill_md
      allow_nil? false
      public? true
    end

    attribute :source_url, :string do
      allow_nil? true
      public? true
    end

    # Bundle columns: populated by the import/materialization plan (1C). Inert here.
    attribute :has_executable_bundle, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :bundle_path, :string do
      allow_nil? true
    end

    attribute :bundle_backend, :string do
      allow_nil? true
    end

    attribute :bundle_byte_size, :integer do
      allow_nil? true
    end

    attribute :file_manifest, {:array, :map} do
      allow_nil? true
      default []
      public? true
      description "[%{path, size, sha256, executable?}] for the bundle"
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end
  end
end
```

- [ ] **Step 5: Register the domain**

In `config/config.exs`, add `Magus.Skills` to the `ash_domains:` list (append it, keeping the list formatting):

```elixir
ash_domains: [
  # ... existing domains ...
  Magus.MCP,
  Magus.Skills
]
```

- [ ] **Step 6: Generate and run the migration**

Run:
```bash
mix ash.codegen --name create_skills
mix ash.migrate
```
Expected: a new migration under `priv/repo/migrations/*_create_skills.exs` creating the `skills` table, applied cleanly. Inspect the generated migration to confirm it creates `skills` with the columns above and the `user_id`/`workspace_id` FKs.

- [ ] **Step 7: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/skills/skill_test.exs`
Expected: PASS (all four tests). The test env runs migrations automatically; if it complains about a missing table, run `MIX_ENV=test mix ash.migrate`.

- [ ] **Step 8: Verify warnings-as-errors**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 9: Commit**

```bash
git add lib/magus/skills/ config/config.exs priv/repo/migrations test/magus/skills/skill_test.exs
git commit -m "feat(skills): add Magus.Skills.Skill resource, domain, and migration"
```

---

### Task 3: Read scopes, sharing actions, calculation, and pub_sub

**Files:**
- Modify: `lib/magus/skills/skill.ex` (add read actions, share actions, calculation, pub_sub)
- Modify: `lib/magus/skills/skills.ex` (add code interfaces)
- Test: `test/magus/skills/skill_workspace_test.exs`

**Interfaces:**
- Consumes: `Magus.Workspaces.Changes.GrantWorkspaceAccess`, `Magus.Workspaces.Changes.RevokeWorkspaceAccess`, `Magus.Workspaces.Calculations.is_shared_to_workspace/1` (existing, same as `Prompt`).
- Produces:
  - `Magus.Skills.my_skills(opts)` (personal skills of the actor).
  - `Magus.Skills.workspace_skills(workspace_id, opts)`.
  - `Magus.Skills.share_skill_to_team(skill, opts)` / `Magus.Skills.unshare_skill_from_team(skill, opts)`.
  - `is_shared_to_workspace` calculation, loadable on read.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/skill_workspace_test.exs`:

```elixir
defmodule Magus.Skills.SkillWorkspaceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills
  alias Magus.Workspaces

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} = Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)
    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  setup do
    creator = generate(user())
    member_user = generate(user())
    ensure_workspace_plan(creator)

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{name: "T", slug: "skill-ws-#{System.unique_integer([:positive])}"},
        actor: creator
      )

    %{creator: creator, member_user: member_user, workspace: workspace}
  end

  test "my_skills returns only the actor's personal skills", %{creator: creator} do
    {:ok, _} = Skills.create_skill(%{name: "mine-a", description: "x"}, actor: creator)
    other = generate(user())
    {:ok, _} = Skills.create_skill(%{name: "theirs", description: "x"}, actor: other)

    names = Skills.my_skills!(actor: creator) |> Enum.map(& &1.name)
    assert "mine-a" in names
    refute "theirs" in names
  end

  test "private workspace skill is hidden from a member without a grant", %{
    creator: creator,
    member_user: member_user,
    workspace: workspace
  } do
    {:ok, skill} =
      Skills.create_skill(
        %{name: "ws-private", description: "x", workspace_id: workspace.id},
        actor: creator
      )

    _ = add_active_member(workspace, creator, member_user)
    assert {:error, _} = Skills.get_skill(skill.id, actor: member_user)
  end

  test "share_to_team creates a workspace grant and the member can read", %{
    creator: creator,
    member_user: member_user,
    workspace: workspace
  } do
    {:ok, skill} =
      Skills.create_skill(
        %{name: "ws-shared", description: "x", workspace_id: workspace.id},
        actor: creator
      )

    _ = add_active_member(workspace, creator, member_user)
    assert {:error, _} = Skills.get_skill(skill.id, actor: member_user)

    {:ok, _} = Skills.share_skill_to_team(skill, actor: creator)
    assert {:ok, _} = Skills.get_skill(skill.id, actor: member_user)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `MIX_ENV=test mix test test/magus/skills/skill_workspace_test.exs`
Expected: FAIL (`my_skills!`, `share_skill_to_team`, `workspace_skills` undefined).

- [ ] **Step 3: Add read scopes and sharing actions to the resource**

In `lib/magus/skills/skill.ex`, inside `actions do ... end`, add these actions (place after the `defaults [:read]` line and the existing `create`/`update`/`destroy`):

```elixir
    read :my_skills do
      filter expr(user_id == ^actor(:id) and is_nil(workspace_id))
    end

    read :workspace_skills do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      prepare build(load: [:is_shared_to_workspace])
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "skill must belong to a workspace"
      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :skill}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "skill must belong to a workspace"
      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :skill}
    end
```

- [ ] **Step 4: Add the calculation and pub_sub blocks to the resource**

In `lib/magus/skills/skill.ex`, after the `relationships do ... end` block, add:

```elixir
  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:skill)
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "workspaces"

    publish_all :create, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :created} end
    end

    publish_all :update, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :updated} end
    end

    publish_all :destroy, [:workspace_id, "skills"] do
      filter fn %{data: s} -> not is_nil(s.workspace_id) end
      transform fn %{data: s} -> %{id: s.id, workspace_id: s.workspace_id, action: :deleted} end
    end
  end
```

- [ ] **Step 5: Add the domain code interfaces**

In `lib/magus/skills/skills.ex`, extend the `resource Magus.Skills.Skill do ... end` block inside `resources do`:

```elixir
    resource Magus.Skills.Skill do
      define :create_skill, action: :create
      define :get_skill, action: :read, get_by: [:id]
      define :update_skill, action: :update
      define :destroy_skill, action: :destroy
      define :list_skills, action: :read
      define :my_skills, action: :my_skills
      define :workspace_skills, action: :workspace_skills, args: [:workspace_id]
      define :share_skill_to_team, action: :share_to_team
      define :unshare_skill_from_team, action: :unshare_from_team
    end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `MIX_ENV=test mix test test/magus/skills/skill_workspace_test.exs`
Expected: PASS (all three tests).

- [ ] **Step 7: Run the full skills test file and warnings check**

Run:
```bash
MIX_ENV=test mix test test/magus/skills/
MIX_ENV=test mix compile --warnings-as-errors
```
Expected: all skills tests pass; no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/skills/ test/magus/skills/skill_workspace_test.exs
git commit -m "feat(skills): add read scopes, share_to_team, is_shared_to_workspace, pub_sub"
```

---

### Task 4: Expose Skill actions to the SPA via AshTypescript RPC

**Files:**
- Modify: `lib/magus/skills/skills.ex` (add `typescript_rpc` block)
- Generate: `frontend/src/lib/ash/ash_rpc.ts` (and `ash_types.ts`) via codegen
- Verify: grep the generated client for the new functions

**Interfaces:**
- Produces: SPA-callable RPC functions `mySkills`, `workspaceSkills`, `getSkill`, `createSkill`, `updateSkill`, `destroySkill`, `shareSkillToTeam`, `unshareSkillFromTeam` in the generated TS client (consumed by the Phase 1 SPA plan).

- [ ] **Step 1: Add the `typescript_rpc` block to the domain**

In `lib/magus/skills/skills.ex`, add a `typescript_rpc` block above `resources do` (the domain already declares `extensions: [AshTypescript.Rpc]`):

```elixir
  typescript_rpc do
    resource Magus.Skills.Skill do
      rpc_action :my_skills, :my_skills
      rpc_action :workspace_skills, :workspace_skills
      rpc_action :create_skill, :create
      rpc_action :update_skill, :update
      rpc_action :destroy_skill, :destroy
      rpc_action :share_skill_to_team, :share_to_team
      rpc_action :unshare_skill_from_team, :unshare_from_team

      rpc_action :get_skill, :read do
        get_by [:id]
      end
    end
  end
```

- [ ] **Step 2: Regenerate the TypeScript client**

Run:
```bash
mix ash_typescript.codegen
```
Expected: `frontend/src/lib/ash/ash_rpc.ts` and `ash_types.ts` are updated. (Config output path is set in `config/config.exs` under `:ash_typescript`.)

- [ ] **Step 3: Verify the generated functions exist**

Run:
```bash
grep -nE "createSkill|shareSkillToTeam|workspaceSkills|getSkill" frontend/src/lib/ash/ash_rpc.ts
```
Expected: matches for each function name (the generator camelCases `rpc_action` names).

- [ ] **Step 4: Confirm compilation**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/skills.ex frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "feat(skills): expose Skill RPC actions to the SPA client"
```

---

### Task 5: Feature kill-switch

**Files:**
- Modify: `lib/magus/skills/skills.ex` (the `enabled?/0` added in Task 2)
- Test: `test/magus/skills/skills_test.exs`

**Interfaces:**
- Produces: `Magus.Skills.enabled?/0` → `boolean`, defaulting to `true`, overridable via `config :magus, Magus.Skills, enabled: false`. Later plans gate discovery/tooling on this.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/skills_test.exs`:

```elixir
defmodule Magus.SkillsTest do
  use ExUnit.Case, async: true

  test "enabled? defaults to true" do
    assert Magus.Skills.enabled?() == true
  end

  test "enabled? respects config override" do
    original = Application.get_env(:magus, Magus.Skills)
    on_exit(fn -> Application.put_env(:magus, Magus.Skills, original) end)

    Application.put_env(:magus, Magus.Skills, enabled: false)
    assert Magus.Skills.enabled?() == false
  end
end
```

- [ ] **Step 2: Run the test**

Run: `MIX_ENV=test mix test test/magus/skills/skills_test.exs`
Expected: PASS if Task 2's `enabled?/0` is in place. If it fails because `enabled?/0` is missing, add it to `lib/magus/skills/skills.ex`:

```elixir
  def enabled? do
    Application.get_env(:magus, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end
```

- [ ] **Step 3: Commit**

```bash
git add lib/magus/skills/skills.ex test/magus/skills/skills_test.exs
git commit -m "feat(skills): add Magus.Skills.enabled? kill-switch"
```

---

## Self-Review

- **Spec coverage (1A scope):** Skill resource + `Magus.Skills` domain + `workspace_scoped_policies` + `:skill` in `ResourceAccess` + `share_to_team`/`unshare_from_team` + `is_shared_to_workspace` + RPC exposure + kill-switch are each implemented by a task. Bundle/secret columns exist (inert) for 1C. Discovery, `load_skill` dispatch, import, materialization, approval, and the SPA UI are explicitly out of scope (1B/1C/SPA plans).
- **Placeholders:** none. Every step has concrete code or an exact command with expected output.
- **Type consistency:** `source_format` values `[:skill_md, :agents_md, :goose, :other]` match the resource and spec; code-interface names (`create_skill`, `get_skill`, `my_skills`, `workspace_skills`, `share_skill_to_team`, `unshare_skill_from_team`) match between the domain (Task 2/3) and tests; `rpc_action` names (Task 4) reuse the same action atoms.
- **Deviation logged:** hard destroy instead of soft-delete `deleted_at` (see Global Constraints).
