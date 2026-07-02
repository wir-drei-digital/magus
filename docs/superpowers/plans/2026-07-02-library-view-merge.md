# Library View Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the SPA's Prompts and Skills modes into one Library mode: a single mixed gallery, one nav store/rail, modal create+edit for both types, plus skill favorites and skills in global search.

**Architecture:** Backend adds a `SkillFavorite` resource (mirror of `PromptFavorite`), a `fulltext_search` action on Skill wired into the `Magus.Search` orchestrator, and a `:library` value in `TabSession.mode`. Frontend replaces the mirrored `/prompts` + `/skills` route trees with a `/library` tree built on a `LibraryItem` discriminated union, one `library-nav` store, generic gallery/card components, and two form dialogs. Old URLs become redirect stubs. Spec: `docs/superpowers/specs/2026-07-02-library-view-merge-design.md`.

**Tech Stack:** Ash 3.x + AshPostgres + AshTypescript, Phoenix, SvelteKit (Svelte 5 runes) SPA in `frontend/`, vitest for frontend unit tests, ExUnit for backend.

## Global Constraints

- NEVER run `mix ash.reset` (wipes all data). Migrations only via `mix ash.codegen` + `mix ash.migrate`.
- Backend verification: `MIX_ENV=test mix compile --warnings-as-errors` must pass before every push (CI enforces it; per-edit hooks don't).
- Frontend verification: `cd frontend && npm run check` (svelte-check) and `cd frontend && npx vitest run`.
- Tests must be structural: assert on `data-testid` hooks and counts, never on visible labels/copy/CSS/URLs in render tests. (Pure-function vitest tests are unaffected.)
- Commit with explicit paths: `git add <paths> && git commit -m "..." -- <paths>` (never bare `git add .`).
- Ash: call resources through domain code interfaces; custom changes/checks in their own module files; `require Ash.Query` before `Ash.Query.filter/2`.
- Nullable Ash tool/NimbleOptions schema fields use `{:or, [type, nil]}`, never a bare type with `default: nil`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Worktree setup (execution context)

This plan runs in a fresh git worktree. Before Task 1, from the worktree root:

```bash
ln -s /Users/daniel/Development/magus/deps deps
ln -s /Users/daniel/Development/magus/frontend/node_modules frontend/node_modules
cp /Users/daniel/Development/magus/.env .env
# Own _build (do NOT symlink _build). First compile is slow; that's expected.
set -a && source .env && set +a
MIX_ENV=test mix compile
```

Run backend tests as `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. Do not run `mix compile` against the main checkout (a dev server may be running there); all work happens in the worktree.

---

### Task 1: Backend — `SkillFavorite` resource + favorites on Skill

**Files:**
- Create: `lib/magus/skills/skill_favorite.ex`
- Create: `lib/magus/skills/skill_favorite/checks/actor_can_read_skill.ex`
- Modify: `lib/magus/skills/skill.ex` (add `has_many :favorites`, `read :my_favorite_skills`, `calculate :is_favorited`)
- Modify: `lib/magus/skills/skills.ex` (domain: resource registration, code interfaces, RPC actions)
- Create: `test/magus/skills/skill_favorite_test.exs`
- Generated: migration via `mix ash.codegen add_skill_favorites`

**Interfaces:**
- Consumes: existing `Magus.Skills.Skill`, `Magus.Skills.get_skill/2`, `Magus.Checks.Helpers.value_from_context/2`, generator `user()` from `Magus.ResourceCase`.
- Produces (later tasks rely on these exact names):
  - Domain code interfaces: `Magus.Skills.favorite_skill/2` (`action: :create`, takes `%{skill_id: id}`), `Magus.Skills.unfavorite_skill/2`, `Magus.Skills.my_skill_favorites/1`, `Magus.Skills.my_favorite_skills/1`.
  - RPC actions (drive TS client names): `my_favorite_skills` (on Skill), `my_skill_favorites`, `favorite_skill`, `unfavorite_skill` (on SkillFavorite) → generated TS functions `myFavoriteSkills`, `mySkillFavorites`, `favoriteSkill`, `unfavoriteSkill`.
  - `Skill.is_favorited` public boolean calculation.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/skill_favorite_test.exs`. Follow the conventions in `test/magus/skills/skill_test.exs` (`use Magus.ResourceCase, async: true`, `generate(user())`).

```elixir
defmodule Magus.Skills.SkillFavoriteTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  defp create_skill!(owner, attrs \\ %{}) do
    {:ok, skill} =
      Skills.create_skill(
        Map.merge(%{name: "fav-target", description: "A skill"}, attrs),
        actor: owner
      )

    skill
  end

  describe "favoriting" do
    test "a user favorites a skill they can read" do
      owner = generate(user())
      skill = create_skill!(owner)

      assert {:ok, favorite} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)
      assert favorite.skill_id == skill.id
      assert favorite.user_id == owner.id
    end

    test "favoriting an inaccessible skill is forbidden" do
      owner = generate(user())
      stranger = generate(user())
      skill = create_skill!(owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Skills.favorite_skill(%{skill_id: skill.id}, actor: stranger)
    end

    test "favoriting the same skill twice fails on the unique identity" do
      owner = generate(user())
      skill = create_skill!(owner)

      assert {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)
      assert {:error, %Ash.Error.Invalid{}} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)
    end
  end

  describe "reading favorites" do
    test "my_skill_favorites returns only the actor's rows" do
      owner = generate(user())
      other = generate(user())
      skill = create_skill!(owner, %{name: "mine"})

      {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      assert {:ok, [row]} = Skills.my_skill_favorites(actor: owner)
      assert row.skill_id == skill.id
      assert {:ok, []} = Skills.my_skill_favorites(actor: other)
    end

    test "my_favorite_skills returns favorited skills and unfavorite removes them" do
      owner = generate(user())
      favorited = create_skill!(owner, %{name: "favorited"})
      _plain = create_skill!(owner, %{name: "plain"})

      {:ok, favorite} = Skills.favorite_skill(%{skill_id: favorited.id}, actor: owner)

      assert {:ok, [skill]} = Skills.my_favorite_skills(actor: owner)
      assert skill.id == favorited.id

      assert :ok = Skills.unfavorite_skill(favorite, actor: owner)
      assert {:ok, []} = Skills.my_favorite_skills(actor: owner)
    end

    test "is_favorited calculation reflects the actor" do
      owner = generate(user())
      other = generate(user())
      skill = create_skill!(owner)
      {:ok, _} = Skills.favorite_skill(%{skill_id: skill.id}, actor: owner)

      {:ok, for_owner} = Skills.get_skill(skill.id, actor: owner, load: [:is_favorited])
      assert for_owner.is_favorited

      # `other` cannot read the personal skill at all; verify the calc is
      # false for a second user on a workspace-visible skill instead.
      {:ok, for_owner_unfavorited} =
        Skills.get_skill(create_skill!(owner, %{name: "unfav"}).id,
          actor: owner,
          load: [:is_favorited]
        )

      refute for_owner_unfavorited.is_favorited
      _ = other
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/skill_favorite_test.exs`
Expected: FAIL — `Skills.favorite_skill/2 is undefined`.

- [ ] **Step 3: Create the check module**

Create `lib/magus/skills/skill_favorite/checks/actor_can_read_skill.ex`, mirroring `lib/magus/library/prompt_favorite/checks/actor_can_read_prompt.ex`:

```elixir
defmodule Magus.Skills.SkillFavorite.Checks.ActorCanReadSkill do
  @moduledoc """
  Verifies that the actor can read the skill they are trying to favorite.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts), do: "actor can read the target skill"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :skill_id)

    case Helpers.value_from_context(context, field) do
      nil ->
        false

      skill_id ->
        case Magus.Skills.get_skill(skill_id, actor: actor) do
          {:ok, _skill} -> true
          {:error, _} -> false
        end
    end
  end
end
```

- [ ] **Step 4: Create the resource**

Create `lib/magus/skills/skill_favorite.ex`, mirroring `lib/magus/library/prompt_favorite.ex`:

```elixir
defmodule Magus.Skills.SkillFavorite do
  @moduledoc """
  Tracks user favorites for skills.
  """
  use Ash.Resource,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "skill_favorites"
    repo Magus.Repo
  end

  typescript do
    type_name "SkillFavorite"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    read :my_favorites do
      filter expr(user_id == ^actor(:id))
    end

    create :create do
      accept [:skill_id]
      change relate_actor(:user)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if Magus.Skills.SkillFavorite.Checks.ActorCanReadSkill
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :skill, Magus.Skills.Skill do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_skill_favorite, [:user_id, :skill_id]
  end
end
```

- [ ] **Step 5: Wire the Skill resource**

In `lib/magus/skills/skill.ex`:

(a) Inside the `actions do` block, after `read :workspace_skills` (line ~48), add:

```elixir
    read :my_favorite_skills do
      prepare fn query, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          Ash.Query.filter(query, exists(favorites, user_id == ^actor_id))
        else
          Ash.Query.filter(query, false)
        end
      end
    end
```

(b) In the `relationships do` block, add:

```elixir
    has_many :favorites, Magus.Skills.SkillFavorite
```

(c) Add a `calculations do` block (or extend the existing one if present), mirroring `Prompt.is_favorited` (`lib/magus/library/prompt.ex:606`):

```elixir
  calculations do
    calculate :is_favorited, :boolean do
      public? true

      calculation fn records, context ->
        require Ash.Query
        actor_id = context.actor && context.actor.id

        if actor_id do
          skill_ids = Enum.map(records, & &1.id)

          favorite_skill_ids =
            Magus.Skills.SkillFavorite
            |> Ash.Query.for_read(:read)
            |> Ash.Query.filter(user_id == ^actor_id and skill_id in ^skill_ids)
            |> Ash.read!(authorize?: false)
            |> Enum.map(& &1.skill_id)
            |> MapSet.new()

          Enum.map(records, &MapSet.member?(favorite_skill_ids, &1.id))
        else
          Enum.map(records, fn _ -> false end)
        end
      end
    end
  end
```

- [ ] **Step 6: Wire the domain**

In `lib/magus/skills/skills.ex`:

(a) In the `resources do` block, inside the existing `resource Magus.Skills.Skill do ... end` block (where `define :get_skill` etc. live — read the file to find it), add:

```elixir
      define :my_favorite_skills, action: :my_favorite_skills
```

then add a new resource block after it:

```elixir
    resource Magus.Skills.SkillFavorite do
      define :favorite_skill, action: :create
      define :unfavorite_skill, action: :destroy
      define :my_skill_favorites, action: :my_favorites
    end
```

(b) In the `typescript_rpc do` block, inside the existing `resource Magus.Skills.Skill do` block (line ~23), add:

```elixir
      rpc_action :my_favorite_skills, :my_favorite_skills
```

and add a new block (mirror `lib/magus/library/library.ex:38-42`):

```elixir
    resource Magus.Skills.SkillFavorite do
      rpc_action :my_skill_favorites, :my_favorites
      rpc_action :favorite_skill, :create
      rpc_action :unfavorite_skill, :destroy
    end
```

- [ ] **Step 7: Generate the migration and run it**

```bash
set -a && source .env && set +a && mix ash.codegen add_skill_favorites && MIX_ENV=test mix ash.migrate && mix ash.migrate
```

Expected: a new migration in `priv/repo/migrations/` creating `skill_favorites` with a unique index on `(user_id, skill_id)`. Inspect it before migrating.

- [ ] **Step 8: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/skill_favorite_test.exs`
Expected: PASS. Also run `MIX_ENV=test mix compile --warnings-as-errors` — clean.

- [ ] **Step 9: Commit**

```bash
git add lib/magus/skills/skill_favorite.ex lib/magus/skills/skill_favorite lib/magus/skills/skill.ex lib/magus/skills/skills.ex test/magus/skills/skill_favorite_test.exs priv/repo/migrations priv/resource_snapshots
git commit -m "feat(skills): skill favorites (SkillFavorite resource, is_favorited calc, RPC)" -- lib/magus/skills priv/repo/migrations priv/resource_snapshots test/magus/skills/skill_favorite_test.exs
```

---

### Task 2: Backend — skills in global search

**Files:**
- Modify: `lib/magus/skills/skill.ex` (add `read :fulltext_search`)
- Modify: `lib/magus/skills/skills.ex` (code interface `fulltext_search_skill`)
- Modify: `lib/magus/search.ex` (`:skill` type + searcher)
- Modify: `lib/magus_web/rpc/search_controller.ex` (`:skill` in `@all_types` + `parse_types`)
- Modify: `test/magus/search_test.exs` (add skill cases)

**Interfaces:**
- Consumes: `Magus.Skills.create_skill/2`, Skill attributes `name`, `display_name`, `description`, `body`, `has_executable_bundle`, `workspace_id`, `inserted_at`.
- Produces: `Magus.Skills.fulltext_search_skill!/2` (`args: [:query]`, offset pagination, actor-scoped); `Magus.Search` results of `type: :skill` with `metadata: %{has_executable_bundle, workspace_id, created_at}`; controller accepts `?type=skill`.

- [ ] **Step 1: Write the failing test**

Read `test/magus/search_test.exs` first and follow its existing structure/case template exactly (how it creates users and calls `Magus.Search.search/2`). Add a describe block:

```elixir
  describe "skill search" do
    test "finds an accessible skill by name and description" do
      owner = generate(user())

      {:ok, _} =
        Magus.Skills.create_skill(
          %{name: "pdf-form-filler", description: "Fill PDF forms automatically"},
          actor: owner
        )

      {:ok, results} = Magus.Search.search("pdf-form-filler", actor: owner, types: [:skill])

      assert [%{type: :skill, title: "pdf-form-filler"} | _] = results
    end

    test "does not surface another user's personal skill" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, _} =
        Magus.Skills.create_skill(
          %{name: "secret-pdf-tool", description: "hidden"},
          actor: owner
        )

      {:ok, results} = Magus.Search.search("secret-pdf-tool", actor: stranger, types: [:skill])

      assert results == []
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/search_test.exs`
Expected: FAIL (`:skill` is not a handled search type / no function clause for `search_type(:skill, ...)`).

- [ ] **Step 3: Add the `fulltext_search` action on Skill**

Skill has no `search_vector` column (unlike Prompt), so match with pg_trgm `similarity` (already installed; Prompt uses it) plus a substring match on body. In `lib/magus/skills/skill.ex` `actions do`, after `read :my_favorite_skills`:

```elixir
    read :fulltext_search do
      description "Search skills by name/display name/description/body (pg_trgm + substring)"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, _context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)

        Ash.Query.filter(
          query,
          fragment(
            "similarity(name, ?) > 0.25 OR similarity(coalesce(display_name, ''), ?) > 0.25 OR similarity(coalesce(description, ''), ?) > 0.2 OR coalesce(body, '') ILIKE '%' || ? || '%'",
            ^search_term,
            ^search_term,
            ^search_term,
            ^search_term
          )
        )
      end
    end
```

In `lib/magus/skills/skills.ex`, in the `resource Magus.Skills.Skill do` code-interface block:

```elixir
      define :fulltext_search_skill, action: :fulltext_search, args: [:query]
```

- [ ] **Step 4: Add the searcher to `Magus.Search`**

In `lib/magus/search.ex`:

(a) Line 11: `@type result_type :: :message | :conversation | :prompt | :skill | :resource | :chunk`

(b) Line 29: `@default_types [:message, :conversation, :prompt, :skill, :resource, :chunk]`

(c) After `search_type(:prompt, ...)` (line ~156), add a clause mirroring it:

```elixir
  defp search_type(:skill, query, limit, actor) do
    Magus.Skills.fulltext_search_skill!(query, page: [limit: limit], actor: actor)
    |> extract_paginated_results()
    |> transform_results(:skill, fn skill ->
      text = Enum.join([skill.name, skill.display_name || "", skill.description || ""], " ")

      %{
        type: :skill,
        id: skill.id,
        title: skill.display_name || skill.name,
        snippet: highlight_snippet(skill.description || skill.body || "", query),
        score: calculate_score(text, query),
        metadata: %{
          has_executable_bundle: skill.has_executable_bundle,
          workspace_id: skill.workspace_id,
          created_at: skill.inserted_at
        }
      }
    end)
  rescue
    e ->
      Logger.warning("Skill search failed: #{inspect(e)}")
      {:ok, []}
  end
```

(d) Also update the `@moduledoc` sentence listing searched resources to include skills.

- [ ] **Step 5: Update the controller**

In `lib/magus_web/rpc/search_controller.ex`:

- Line 13: `@all_types [:message, :conversation, :prompt, :skill, :resource, :chunk]`
- After `defp parse_types("prompt"), do: [:prompt]` add: `defp parse_types("skill"), do: [:skill]`

Check `test/magus_web/rpc/search_controller_test.exs`: if it asserts the full type list or parse behavior, extend it the same way.

- [ ] **Step 6: Run tests to verify they pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/search_test.exs test/magus_web/rpc/search_controller_test.exs test/magus/skills/`
Expected: PASS. Then `MIX_ENV=test mix compile --warnings-as-errors` — clean.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills lib/magus/search.ex lib/magus_web/rpc/search_controller.ex test/magus/search_test.exs test/magus_web/rpc/search_controller_test.exs
git commit -m "feat(search): include skills in unified global search" -- lib/magus/skills lib/magus/search.ex lib/magus_web/rpc/search_controller.ex test/magus/search_test.exs test/magus_web/rpc/search_controller_test.exs
```

---

### Task 3: Backend — `:library` TabSession mode + TS client regeneration

**Files:**
- Modify: `lib/magus/workbench/tab_session.ex:129`
- Modify: `test/magus/workbench/tab_session_test.exs`
- Generated: `frontend/src/lib/ash/ash_rpc.ts` + `ash_types.ts` via `mix ash_typescript.codegen`
- Possibly generated: Ash snapshot/migration via `mix ash.codegen`

**Interfaces:**
- Consumes: existing `set_mode` update action.
- Produces: `TabSession['mode']` TS union includes `'library'` (keeps `'prompts'`/`'skills'` for saved sessions); generated TS functions from Task 1/2 (`myFavoriteSkills`, `mySkillFavorites`, `favoriteSkill`, `unfavoriteSkill`) exist in `ash_rpc.ts`.

- [ ] **Step 1: Write the failing test**

Read `test/magus/workbench/tab_session_test.exs` and follow its setup helpers. Add:

```elixir
    test "set_mode accepts :library" do
      # Use the file's existing session-creation helper/pattern for the actor.
      user = generate(user())

      {:ok, session} =
        Magus.Workbench.get_or_create_tab_session(%{user_id: user.id, workspace_id: nil},
          actor: user
        )

      {:ok, updated} = Magus.Workbench.set_tab_session_mode(session, %{mode: :library}, actor: user)
      assert updated.mode == :library
    end
```

(Adjust the two domain-call names to whatever code interfaces the existing tests in that file use — read the file first; the assertion `updated.mode == :library` is the point.)

- [ ] **Step 2: Run to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/workbench/tab_session_test.exs`
Expected: FAIL with an atom-constraint error (`:library` not in one_of).

- [ ] **Step 3: Extend the constraint**

`lib/magus/workbench/tab_session.ex:129`:

```elixir
      constraints one_of: [:chat, :brain, :agents, :prompts, :files, :skills, :library]
```

Keep `:prompts`/`:skills`: saved sessions still hold them; the SPA maps them to `library` on restore (Task 7).

- [ ] **Step 4: Codegen**

```bash
set -a && source .env && set +a && mix ash.codegen add_library_tab_mode
```

Expected: likely "no changes" (atom one_of has no DB check constraint). If a migration IS generated, inspect and `mix ash.migrate` + `MIX_ENV=test mix ash.migrate`.

```bash
mix ash_typescript.codegen
```

Expected: `frontend/src/lib/ash/ash_rpc.ts` (and `ash_types.ts` if configured) regenerate with `'library'` in the TabSession mode union AND the Task 1 skill-favorite RPC functions.

- [ ] **Step 5: Run tests to verify they pass**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/workbench/ && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean compile. Also `cd frontend && npm run check` still passes (the union widened; nothing narrows on it yet).

- [ ] **Step 6: Commit**

```bash
git add lib/magus/workbench/tab_session.ex test/magus/workbench/tab_session_test.exs frontend/src/lib/ash frontend/src/lib/ash/ash_types.ts priv/resource_snapshots
git commit -m "feat(workbench): add :library tab session mode; regen TS client" -- lib/magus/workbench test/magus/workbench frontend/src/lib/ash priv/resource_snapshots
```

---

### Task 4: Frontend — api.ts wrappers for skill favorites + search type

**Files:**
- Modify: `frontend/src/lib/ash/api.ts`

**Interfaces:**
- Consumes: generated `rpc.myFavoriteSkills`, `rpc.mySkillFavorites`, `rpc.favoriteSkill`, `rpc.unfavoriteSkill` from Task 3's codegen; existing `SkillSummary`/`SkillDetail` types and the `skillFields` selection; existing `run()` wrapper pattern (see `myFavoritePrompts` / `myPromptFavorites` / `favoritePrompt` / `unfavoritePrompt` wrappers around line 2697-2801 for the exact shape to mirror).
- Produces (exact exports later tasks import):
  - `SkillSummary` and `SkillDetail` gain `isFavorited: boolean` (add `"isFavorited"` to the skill field selections; it is the Task 1 calculation).
  - `myFavoriteSkills(): Promise<RpcResult<SkillSummary[]>>`
  - `mySkillFavorites(): Promise<RpcResult<{ id: string; skillId: string }[]>>`
  - `favoriteSkill(skillId: string): Promise<RpcResult<unknown>>`
  - `unfavoriteSkill(favoriteId: string): Promise<RpcResult<unknown>>`
  - `SearchResultType` (line 487) gains `'skill'`: `export type SearchResultType = 'message' | 'conversation' | 'prompt' | 'skill' | 'resource' | 'chunk';`

- [ ] **Step 1: Add `"isFavorited"` to the skill field selections**

Find the skill fields literals used by `mySkills` / `workspaceSkills` / `getSkill` (near `api.ts:4644-4734`) and add `"isFavorited"` to both the summary and detail field lists. Extend the `SkillSummary`/`SkillDetail` app-level types with `isFavorited: boolean`.

- [ ] **Step 2: Add the four wrappers**

Mirror the prompt-favorite wrappers exactly (same `run()` + field-selection style; copy their shape, substitute skill names). Place them next to the other skill wrappers.

- [ ] **Step 3: Widen `SearchResultType`**

Line 487 as specified above. If `searchAll`'s `type` param is validated against a literal list, add `'skill'` there too.

- [ ] **Step 4: Verify**

Run: `cd frontend && npm run check`
Expected: PASS (0 errors). `npx vitest run` still green.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/ash/api.ts
git commit -m "feat(spa): skill favorite wrappers + isFavorited field + skill search type" -- frontend/src/lib/ash/api.ts
```

---

### Task 5: Frontend — `LibraryItem` module (pure functions) + tests

**Files:**
- Create: `frontend/src/lib/library/items.ts`
- Create: `frontend/src/lib/library/items.test.ts`

**Interfaces:**
- Consumes: `PromptSummary`, `SkillSummary` from `$lib/ash/api` (type-only imports).
- Produces (exact exports):

```ts
export type LibraryItem =
	| { kind: 'prompt'; id: string; prompt: PromptSummary }
	| { kind: 'skill'; id: string; skill: SkillSummary };

export function promptItem(prompt: PromptSummary): LibraryItem;
export function skillItem(skill: SkillSummary): LibraryItem;
export function itemName(item: LibraryItem): string;
export function itemDescription(item: LibraryItem): string | null;
export function itemIsFavorited(item: LibraryItem): boolean;
export function itemUseCount(item: LibraryItem): number; // skills => 0
export function itemMatches(item: LibraryItem, query: string): boolean;
export function partitionLibrary(input: {
	prompts: PromptSummary[];
	favoritePrompts: PromptSummary[];
	skills: SkillSummary[];
	favoriteSkills: SkillSummary[];
}): {
	all: LibraryItem[];
	favorites: LibraryItem[];
	shared: LibraryItem[];
	personal: LibraryItem[];
};
```

- [ ] **Step 1: Write the failing tests**

`frontend/src/lib/library/items.test.ts` (use minimal `as`-cast fixtures; vitest):

```ts
import { describe, expect, it } from 'vitest';
import type { PromptSummary, SkillSummary } from '$lib/ash/api';
import {
	itemIsFavorited,
	itemMatches,
	itemName,
	itemUseCount,
	partitionLibrary,
	promptItem,
	skillItem
} from './items';

function prompt(overrides: Partial<PromptSummary> = {}): PromptSummary {
	return {
		id: 'p1',
		name: 'Summarizer',
		description: null,
		content: 'Summarize this text',
		type: 'user',
		useCount: 3,
		isFavorited: false,
		isSharedToWorkspace: false,
		isPublic: false,
		tags: [],
		...overrides
	} as PromptSummary;
}

function skill(overrides: Partial<SkillSummary> = {}): SkillSummary {
	return {
		id: 's1',
		name: 'pdf-tools',
		displayName: null,
		description: 'Work with PDFs',
		workspaceId: null,
		isFavorited: false,
		isSharedToWorkspace: false,
		hasExecutableBundle: false,
		requestedTools: [],
		version: null,
		...overrides
	} as SkillSummary;
}

describe('item accessors', () => {
	it('itemName prefers skill displayName and falls back to name', () => {
		expect(itemName(skillItem(skill({ displayName: 'PDF Tools' })))).toBe('PDF Tools');
		expect(itemName(skillItem(skill()))).toBe('pdf-tools');
		expect(itemName(promptItem(prompt()))).toBe('Summarizer');
	});

	it('itemUseCount is 0 for skills', () => {
		expect(itemUseCount(promptItem(prompt({ useCount: 7 })))).toBe(7);
		expect(itemUseCount(skillItem(skill()))).toBe(0);
	});

	it('itemIsFavorited reads both kinds', () => {
		expect(itemIsFavorited(promptItem(prompt({ isFavorited: true })))).toBe(true);
		expect(itemIsFavorited(skillItem(skill({ isFavorited: true })))).toBe(true);
		expect(itemIsFavorited(skillItem(skill()))).toBe(false);
	});

	it('itemMatches searches prompt content and skill body-less fields', () => {
		expect(itemMatches(promptItem(prompt()), 'summarize this')).toBe(true);
		expect(itemMatches(skillItem(skill()), 'pdfs')).toBe(true);
		expect(itemMatches(skillItem(skill()), 'zzz')).toBe(false);
		expect(itemMatches(promptItem(prompt()), '')).toBe(true);
	});
});

describe('partitionLibrary', () => {
	it('merges kinds into all/favorites/shared/personal', () => {
		const sharedPrompt = prompt({ id: 'p-shared', isSharedToWorkspace: true });
		const personalPrompt = prompt({ id: 'p-personal' });
		const workspaceSkill = skill({ id: 's-ws', workspaceId: 'ws1' });
		const personalSkill = skill({ id: 's-personal' });
		const favPrompt = prompt({ id: 'p-fav', isFavorited: true });
		const favSkill = skill({ id: 's-fav', isFavorited: true });

		const result = partitionLibrary({
			prompts: [sharedPrompt, personalPrompt, favPrompt],
			favoritePrompts: [favPrompt],
			skills: [workspaceSkill, personalSkill, favSkill],
			favoriteSkills: [favSkill]
		});

		expect(result.all).toHaveLength(6);
		expect(result.favorites.map((i) => i.id)).toEqual(['p-fav', 's-fav']);
		expect(result.shared.map((i) => i.id)).toEqual(['p-shared', 's-ws']);
		expect(result.personal.map((i) => i.id).sort()).toEqual(
			['p-fav', 'p-personal', 's-fav', 's-personal'].sort()
		);
	});
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd frontend && npx vitest run src/lib/library/items.test.ts`
Expected: FAIL — module `./items` not found.

- [ ] **Step 3: Implement `frontend/src/lib/library/items.ts`**

```ts
import type { PromptSummary, SkillSummary } from '$lib/ash/api';

/**
 * The Library gallery's discriminated union over the two backend resources.
 * Resources stay separate (see the 2026-07-02 library-view-merge spec); this
 * module is the single place that knows how to read both uniformly.
 */
export type LibraryItem =
	| { kind: 'prompt'; id: string; prompt: PromptSummary }
	| { kind: 'skill'; id: string; skill: SkillSummary };

export function promptItem(prompt: PromptSummary): LibraryItem {
	return { kind: 'prompt', id: prompt.id, prompt };
}

export function skillItem(skill: SkillSummary): LibraryItem {
	return { kind: 'skill', id: skill.id, skill };
}

export function itemName(item: LibraryItem): string {
	return item.kind === 'prompt' ? item.prompt.name : (item.skill.displayName ?? item.skill.name);
}

export function itemDescription(item: LibraryItem): string | null {
	return item.kind === 'prompt' ? (item.prompt.description ?? null) : (item.skill.description ?? null);
}

export function itemIsFavorited(item: LibraryItem): boolean {
	return item.kind === 'prompt' ? item.prompt.isFavorited : item.skill.isFavorited;
}

/** Skills carry no use count; they sort as 0 under "Most used". */
export function itemUseCount(item: LibraryItem): number {
	return item.kind === 'prompt' ? item.prompt.useCount : 0;
}

export function itemMatches(item: LibraryItem, query: string): boolean {
	const q = query.trim().toLowerCase();
	if (!q) return true;
	const haystack =
		item.kind === 'prompt'
			? [item.prompt.name, item.prompt.description ?? '', item.prompt.content]
			: [item.skill.name, item.skill.displayName ?? '', item.skill.description ?? ''];
	return haystack.some((text) => text.toLowerCase().includes(q));
}

/**
 * Merge both kinds into the rail's four scopes.
 *  - shared: prompts shared to the workspace + skills belonging to a workspace
 *  - personal: everything else (prompt not shared / skill without workspace)
 *  - favorites: the dedicated favorite lists (overlapping with the others)
 */
export function partitionLibrary(input: {
	prompts: PromptSummary[];
	favoritePrompts: PromptSummary[];
	skills: SkillSummary[];
	favoriteSkills: SkillSummary[];
}): {
	all: LibraryItem[];
	favorites: LibraryItem[];
	shared: LibraryItem[];
	personal: LibraryItem[];
} {
	const promptItems = input.prompts.map(promptItem);
	const skillItems = input.skills.map(skillItem);

	const shared = [
		...input.prompts.filter((p) => p.isSharedToWorkspace).map(promptItem),
		...input.skills.filter((s) => s.workspaceId != null).map(skillItem)
	];
	const personal = [
		...input.prompts.filter((p) => !p.isSharedToWorkspace).map(promptItem),
		...input.skills.filter((s) => s.workspaceId == null).map(skillItem)
	];
	const favorites = [
		...input.favoritePrompts.map(promptItem),
		...input.favoriteSkills.map(skillItem)
	];

	return { all: [...promptItems, ...skillItems], favorites, shared, personal };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd frontend && npx vitest run src/lib/library/items.test.ts`
Expected: PASS. Then `npm run check` — clean.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/library
git commit -m "feat(spa): LibraryItem union + partition helpers" -- frontend/src/lib/library
```

---

### Task 6: Frontend — `library-nav` store + shell rail

**Files:**
- Create: `frontend/src/lib/stores/library-nav.svelte.ts`
- Create: `frontend/src/lib/components/shell/library-nav.svelte`

**Interfaces:**
- Consumes: Task 4 wrappers (`myFavoriteSkills` etc.), Task 5 `partitionLibrary`/`LibraryItem`; existing `myPrompts`, `myFavoritePrompts`, `workspacePrompts`, `mySkills`, `workspaceSkills`; the store pattern of `frontend/src/lib/stores/prompts-nav.svelte.ts` (loadKey dedup) and the rail pattern of `frontend/src/lib/components/shell/prompts-nav.svelte`.
- Produces:
  - `export const libraryNav` singleton with: `all/favorites/shared/personal: LibraryItem[]`, `loading: boolean`, `importOpen: boolean`, `createPromptOpen: boolean`, `createSkillOpen: boolean`, `load(workspaceId: string | null, force?: boolean): Promise<void>`, `refresh(): void`, plus derived-style getters `promptTags(): { name: string; count: number }[]` is NOT needed here (the rail computes tags itself from `all`).
  - `LibraryNav` rail component (default export) rendering scopes All/Favorites/Shared/Personal + prompt Tags group, with `data-testid="library-nav"`, `data-testid="library-scope-{key}"`, `data-testid="library-tags-nav"`, `data-testid="library-tag"`.

- [ ] **Step 1: Implement the store**

`frontend/src/lib/stores/library-nav.svelte.ts`:

```ts
import {
	myFavoritePrompts,
	myFavoriteSkills,
	myPrompts,
	mySkills,
	workspacePrompts,
	workspaceSkills
} from '$lib/ash/api';
import { partitionLibrary, type LibraryItem } from '$lib/library/items';

/**
 * Library-mode nav lists (All / Favorites / Shared / Personal across prompts
 * AND skills). Replaces the old prompts-nav + skills-nav pair. Cached in a
 * singleton so detail views and dialogs can refresh the nav after mutations
 * without prop drilling.
 */
class LibraryNav {
	all = $state<LibraryItem[]>([]);
	favorites = $state<LibraryItem[]>([]);
	shared = $state<LibraryItem[]>([]);
	personal = $state<LibraryItem[]>([]);
	loading = $state(true);

	/** Global dialog flags (rendered once in nav-pane). */
	importOpen = $state(false);
	createPromptOpen = $state(false);
	createSkillOpen = $state(false);

	#workspaceId: string | null = null;
	#loadKey: string | null = null;

	async load(workspaceId: string | null, force = false): Promise<void> {
		const key = workspaceId ?? '';
		// Effects re-run on unrelated session changes; identical keys are
		// no-ops unless forced (refresh after a mutation).
		if (!force && this.#loadKey === key) return;
		this.#workspaceId = workspaceId;
		this.#loadKey = key;
		this.loading = true;

		try {
			const [favoritePrompts, prompts, skills, favoriteSkills] = await Promise.all([
				myFavoritePrompts(),
				workspaceId ? workspacePrompts(workspaceId) : myPrompts(),
				workspaceId ? workspaceSkills(workspaceId) : mySkills(),
				myFavoriteSkills()
			]);

			if (this.#loadKey !== key) return;

			const partitioned = partitionLibrary({
				prompts: prompts.success ? prompts.data : [],
				favoritePrompts: favoritePrompts.success ? favoritePrompts.data : [],
				skills: skills.success ? skills.data : [],
				favoriteSkills: favoriteSkills.success ? favoriteSkills.data : []
			});

			this.all = partitioned.all;
			this.favorites = partitioned.favorites;
			this.shared = partitioned.shared;
			this.personal = partitioned.personal;
		} finally {
			if (this.#loadKey === key) this.loading = false;
		}
	}

	refresh(): void {
		void this.load(this.#workspaceId, true);
	}
}

export const libraryNav = new LibraryNav();
```

- [ ] **Step 2: Implement the rail**

`frontend/src/lib/components/shell/library-nav.svelte` — port `prompts-nav.svelte` (keep its skeleton-loading block and Sidebar structure verbatim) with these changes:

- Import `libraryNav` instead of `promptsNav`; load effect: `void libraryNav.load(session.user?.currentWorkspaceId ?? null);`
- Scopes (counts span both kinds):

```ts
	const scopes = $derived([
		{ key: null as string | null, label: 'All', icon: LayoutGrid, count: libraryNav.all.length },
		{ key: 'favorites', label: 'Favorites', icon: Star, count: libraryNav.favorites.length },
		// Shared/Personal only mean something inside a workspace.
		...(session.user?.currentWorkspaceId
			? [
					{ key: 'shared', label: 'Shared', icon: Users, count: libraryNav.shared.length },
					{ key: 'personal', label: 'Personal', icon: User, count: libraryNav.personal.length }
				]
			: [])
	]);
```

- Tags stay prompt-only, computed from the merged list:

```ts
	const tags = $derived.by(() => {
		const counts = new Map<string, number>();
		for (const item of libraryNav.all) {
			if (item.kind !== 'prompt') continue;
			for (const tag of item.prompt.tags) counts.set(tag.name, (counts.get(tag.name) ?? 0) + 1);
		}
		return [...counts.entries()]
			.map(([name, count]) => ({ name, count }))
			.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
	});
```

- Hrefs and actives target `/library`: `scopeHref = (key) => key ? `${base}/library?scope=${key}` : `${base}/library``; `tagHref = (name) => `${base}/library?tag=${encodeURIComponent(name)}``; `inLibrary = page.url.pathname.startsWith(`${base}/library`)`.
- data-testids: `library-nav`, `library-scope-{scope.key ?? 'all'}`, `library-tags-nav`, `library-tag`.
- Group label stays `Library`; loading guard: `libraryNav.loading && libraryNav.all.length === 0`.

- [ ] **Step 3: Verify**

Run: `cd frontend && npm run check && npx vitest run`
Expected: PASS (component not yet referenced; no unused-import errors in it).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/stores/library-nav.svelte.ts frontend/src/lib/components/shell/library-nav.svelte
git commit -m "feat(spa): library-nav store + merged library rail" -- frontend/src/lib/stores/library-nav.svelte.ts frontend/src/lib/components/shell/library-nav.svelte
```

---

### Task 7: Frontend — prompt form dialog (create + edit, type dropdown)

**Files:**
- Create: `frontend/src/lib/components/shell/prompt-form-dialog.svelte`
- Modify: `frontend/src/lib/components/shell/new-resource-dialog.svelte` (drop the `prompt` kind)
- Modify: `frontend/src/lib/components/chat/conversation-view.svelte` (use the new dialog)

**Interfaces:**
- Consumes: `createPrompt`, `updatePrompt`, `PromptDetail`, `PromptType` from `$lib/ash/api`; `libraryNav` (Task 6); `Dialog`, `Button`, `CONTROL_CLASS`, `TEXTAREA_CLASS` from the existing kits; the current edit-form fields in `frontend/src/routes/prompts/[promptId]/+page.svelte:219-278` (name, type select, description, additionalInformation, content).
- Produces: `PromptFormDialog` with props:

```ts
let {
	open = $bindable(false),
	prompt = null,        // PromptDetail | null — null means create mode
	initialBody = '',     // create-mode prefill (create-prompt-from-message)
	onSaved
}: {
	open?: boolean;
	prompt?: PromptDetail | null;
	initialBody?: string;
	onSaved?: (prompt: PromptDetail) => void;
} = $props();
```

- [ ] **Step 1: Implement the dialog**

`frontend/src/lib/components/shell/prompt-form-dialog.svelte`:

```svelte
<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { createPrompt, updatePrompt, type PromptDetail, type PromptType } from '$lib/ash/api';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { CONTROL_CLASS, TEXTAREA_CLASS } from '$lib/components/crud';

	let {
		open = $bindable(false),
		prompt = null,
		initialBody = '',
		onSaved
	}: {
		open?: boolean;
		prompt?: PromptDetail | null;
		initialBody?: string;
		onSaved?: (prompt: PromptDetail) => void;
	} = $props();

	const isEdit = $derived(prompt !== null);

	let name = $state('');
	let content = $state('');
	let description = $state('');
	let additionalInformation = $state('');
	let type = $state<PromptType>('user');
	let saving = $state(false);
	let error = $state<string | null>(null);

	// Seed the form each time the dialog opens (edit: from the prompt; create:
	// blank plus the optional initialBody prefill).
	$effect(() => {
		if (!open) return;
		if (prompt) {
			name = prompt.name;
			content = prompt.content;
			description = prompt.description ?? '';
			additionalInformation = prompt.additionalInformation ?? '';
			type = prompt.type;
		} else {
			name = '';
			content = initialBody;
			description = '';
			additionalInformation = '';
			type = 'user';
		}
		error = null;
	});

	const canSave = $derived(name.trim() !== '' && content.trim() !== '' && !saving);

	async function save() {
		if (!canSave) return;
		saving = true;
		error = null;

		if (prompt) {
			const result = await updatePrompt(prompt.id, {
				name: name.trim(),
				content,
				type,
				description: description.trim() || undefined,
				additionalInformation: additionalInformation.trim() || undefined
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Prompt could not be saved';
				return;
			}
			libraryNav.refresh();
			open = false;
			onSaved?.(result.data);
		} else {
			const result = await createPrompt({
				name: name.trim(),
				content,
				type,
				description: description.trim() || undefined,
				workspaceId: session.user?.currentWorkspaceId ?? null
			});
			saving = false;
			if (!result.success) {
				error = result.errors[0]?.message ?? 'Prompt could not be created';
				return;
			}
			libraryNav.refresh();
			open = false;
			await goto(`${base}/library/prompts/${result.data.id}`);
		}
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-2xl" data-testid="prompt-form-dialog">
		<Dialog.Header>
			<Dialog.Title>{isEdit ? 'Edit prompt' : 'New prompt'}</Dialog.Title>
			<Dialog.Description>
				{isEdit
					? 'Update this prompt and save your changes.'
					: 'Create a reusable prompt for your library.'}
			</Dialog.Description>
		</Dialog.Header>

		<form
			class="flex max-h-[70vh] flex-col gap-3 overflow-y-auto"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Name</span>
				<!-- svelte-ignore a11y_autofocus — single-purpose dialog -->
				<input
					type="text"
					bind:value={name}
					autofocus
					required
					data-testid="prompt-form-name"
					class={CONTROL_CLASS}
				/>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Type</span>
				<select bind:value={type} data-testid="prompt-form-type" class="{CONTROL_CLASS} w-48">
					<option value="user">User prompt</option>
					<option value="system">System prompt</option>
				</select>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Description</span>
				<input bind:value={description} class={CONTROL_CLASS} data-testid="prompt-form-description" />
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Additional information</span>
				<textarea bind:value={additionalInformation} rows="2" class={TEXTAREA_CLASS}></textarea>
			</label>

			<label class="flex flex-col gap-1.5 text-sm">
				<span class="text-xs font-medium text-muted-foreground">Content</span>
				<textarea
					bind:value={content}
					required
					rows="10"
					data-testid="prompt-form-content"
					class="{TEXTAREA_CLASS} font-mono"
				></textarea>
			</label>

			{#if error}
				<p class="text-xs text-destructive">{error}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
				<Button type="submit" disabled={!canSave} data-testid="prompt-form-save">
					{saving ? 'Saving…' : isEdit ? 'Save' : 'Create'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
```

Note: `createPrompt` today is called with `description` omitted (`new-resource-dialog.svelte:73-78` passes only name/content/type/workspaceId) — check the wrapper's accepted input in `api.ts`; if `description` is not in the create input type, extend the wrapper (the backend `create` accepts `:description`, see `lib/magus/library/prompt.ex:185-199`).

- [ ] **Step 2: Shrink `new-resource-dialog.svelte`**

- `export type NewResourceKind = 'agent' | 'brain';` (drop `'prompt'`).
- Remove the `prompt` entry from `COPY`, the `kind === 'prompt'` branch in `create()`, the prompt content `{#if kind === 'prompt'}` template branch, the `createPrompt` and `promptsNav` imports, and the prompt clause in `canCreate` (becomes `name.trim() !== '' && !saving`).

- [ ] **Step 3: Rewire `conversation-view.svelte`**

Line 18 imports `NewResourceDialog`; line 487 uses `kind="prompt" ... initialBody={promptFromMessage}`. Replace with:

```svelte
import PromptFormDialog from '$lib/components/shell/prompt-form-dialog.svelte';
...
<PromptFormDialog bind:open={promptDialogOpen} initialBody={promptFromMessage} />
```

(Keep the `NewResourceDialog` import ONLY if the file uses it for other kinds — check; if `prompt` was its only use there, remove the import.)

- [ ] **Step 4: Verify**

Run: `cd frontend && npm run check`
Expected: FAIL only in files not yet migrated is NOT acceptable — `nav-pane.svelte` and `prompt-gallery.svelte` still pass `kind='prompt'`/`kind={createKind}`. Fix them now minimally: in `nav-pane.svelte`, change `let createKind = $state<NewResourceKind>('prompt')` to `'brain'` and change the prompts-mode "New prompt" button (line 156-160) to open the new dialog via a local `promptFormOpen` state + render `<PromptFormDialog bind:open={promptFormOpen} />`; in `prompt-gallery.svelte`, swap `NewResourceDialog kind="prompt"` for `PromptFormDialog` the same way (the gallery is deleted in Task 11; this keeps the tree green meanwhile). Re-run `npm run check` — PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/shell/prompt-form-dialog.svelte frontend/src/lib/components/shell/new-resource-dialog.svelte frontend/src/lib/components/chat/conversation-view.svelte frontend/src/lib/components/shell/nav-pane.svelte frontend/src/routes/prompts/components/prompt-gallery.svelte frontend/src/lib/ash/api.ts
git commit -m "feat(spa): prompt form dialog (create+edit, user/system type dropdown)" -- frontend/src/lib/components frontend/src/routes/prompts frontend/src/lib/ash/api.ts
```

---

### Task 8: Frontend — skill form dialog (create + edit)

**Files:**
- Create: `frontend/src/lib/components/shell/skill-form-dialog.svelte`

**Interfaces:**
- Consumes: `createSkill`, `updateSkill`, `SkillDetail` from `$lib/ash/api`; `libraryNav`; the existing form logic in `frontend/src/routes/skills/[skillId]/+page.svelte:38-166` (NAME_RE, validateName, parseTools, field set).
- Produces: `SkillFormDialog` with props:

```ts
let {
	open = $bindable(false),
	skill = null,      // SkillDetail | null — null means create mode
	onSaved
}: {
	open?: boolean;
	skill?: SkillDetail | null;
	onSaved?: (skill: SkillDetail) => void;
} = $props();
```

- [ ] **Step 1: Implement the dialog**

Port the form from `routes/skills/[skillId]/+page.svelte` into a `Dialog.Root` shell (same structure as Task 7's dialog: `sm:max-w-2xl`, scrollable form). Exact behavior:

- State: `name`, `displayName`, `description`, `body`, `requestedToolsRaw`, `nameError`, `saving`, `error` — seeded by an `$effect` on `open` (edit: from `skill` via the old `syncForm` logic incl. `requestedToolsRaw = (skill.requestedTools ?? []).join(', ')`; create: all blank).
- Keep `NAME_RE = /^[a-z0-9-]{1,64}$/`, `validateName()`, `parseTools()` verbatim from the old file.
- `canSave` as in the old file (`name` non-empty + regex + `description` non-empty, and `!saving`).
- `save()`: create branch calls `createSkill({ name, displayName? , description, body?, requestedTools?, workspaceId: session.user?.currentWorkspaceId ?? null })` then `libraryNav.refresh(); open = false; await goto(`${base}/library/skills/${result.data.id}`)`. Edit branch calls `updateSkill(skill.id, {...})` (same nullable mapping as the old file: `displayName.trim() || null`, `body.trim() || null`, `requestedTools: tools.length > 0 ? tools : null`) then `libraryNav.refresh(); open = false; onSaved?.(result.data)`.
- Fields exactly as the old form: Name (with hint + error, `data-testid="skill-form-name"`), Display name, Description (required), Instructions body (`rows="10"`, font-mono, `data-testid="skill-form-body"`), Required tools. Save button `data-testid="skill-form-save"`, label `Create skill` / `Save`.
- Root `Dialog.Content` gets `data-testid="skill-form-dialog"`.
- Artifacts note: the dialog does NOT handle bundle upload (import dialog owns that); the reader keeps showing the manifest.

- [ ] **Step 2: Verify**

Run: `cd frontend && npm run check && npx vitest run`
Expected: PASS (component not yet referenced).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/components/shell/skill-form-dialog.svelte
git commit -m "feat(spa): skill form dialog (create+edit in modal)" -- frontend/src/lib/components/shell/skill-form-dialog.svelte
```

---

### Task 9: Frontend — library gallery + card components

**Files:**
- Create: `frontend/src/routes/library/components/library-card.svelte`
- Create: `frontend/src/routes/library/components/library-gallery.svelte`

**Interfaces:**
- Consumes: `LibraryItem` + helpers (Task 5), `libraryNav` (Task 6), favorite RPCs (Task 4 + existing prompt ones), the visual shells of `prompt-card.svelte` / `skill-card.svelte` / `prompt-gallery.svelte` (all still present until Task 11 — read them for exact classes).
- Produces:
  - `LibraryCard` props: `{ item: LibraryItem; href: string; selected?: boolean; compact?: boolean; onToggleFavorite?: (item: LibraryItem) => void }`, `data-testid="library-card"`, `data-kind={item.kind}`, `data-selected`, favorite button `data-testid="library-card-favorite"`.
  - `LibraryGallery` props: `{ selectedId?: string | null; compact?: boolean }`, root `data-testid="library-gallery"`.

- [ ] **Step 1: Implement `library-card.svelte`**

Merge the two cards. Shared shell = `prompt-card.svelte`'s outer `div.group/card` + anchor + favorite-star-overlay structure (favorite star now on BOTH kinds). Kind-specific interior:

- Header icon: prompt → `Sparkles` (system) / `ScrollText` (user) as today; skill → `BookMarked`.
- Type badge line under the name area or in the footer: a small pill with `PROMPT` / `SKILL` — implement as `<span class="rounded-full border border-input bg-secondary px-1.5 py-0.5 text-[9px] font-semibold tracking-wide text-muted-foreground uppercase">{item.kind}</span>` placed first in the footer row.
- Prompt body preview (`font-mono line-clamp` of `prompt.content`) only for prompts; skills show description via the header block (as skill-card does today).
- Footer: prompt → tag chips (max 2 / 1 compact) + `Used N×` right-aligned; skill → sandbox badge when `hasExecutableBundle` + tools-count chip + `v{version}` (copy the chips verbatim from `skill-card.svelte:39-65`).
- Favorite button identical to `prompt-card.svelte:71-82` but reading `itemIsFavorited(item)` and calling `onToggleFavorite?.(item)`.

- [ ] **Step 2: Implement `library-gallery.svelte`**

Port `prompt-gallery.svelte` structurally (header / toolbar / scroll grid / empty states) with these exact changes:

```svelte
<script lang="ts">
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { Download, LibraryBig, Plus, Search } from '@lucide/svelte';
	import {
		favoritePrompt,
		favoriteSkill,
		myPromptFavorites,
		mySkillFavorites,
		unfavoritePrompt,
		unfavoriteSkill
	} from '$lib/ash/api';
	import {
		itemIsFavorited,
		itemMatches,
		itemName,
		itemUseCount,
		type LibraryItem
	} from '$lib/library/items';
	import { libraryNav } from '$lib/stores/library-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { Button } from '$lib/components/ui/button';
	import { EmptyState } from '$lib/components/ui/empty-state';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import LibraryCard from './library-card.svelte';

	let { selectedId = null, compact = false }: { selectedId?: string | null; compact?: boolean } =
		$props();

	const TYPES = [
		['all', 'All'],
		['prompts', 'Prompts'],
		['skills', 'Skills']
	] as const;

	// ?type= comes from the legacy /prompts and /skills redirects; read once.
	const urlType = page.url.searchParams.get('type');
	let typeFilter = $state<'all' | 'prompts' | 'skills'>(
		urlType === 'prompts' || urlType === 'skills' ? urlType : 'all'
	);
	let query = $state('');
	let sort = $state<'used' | 'name'>('used');

	$effect(() => {
		void libraryNav.load(session.user?.currentWorkspaceId ?? null);
	});

	const scope = $derived(page.url.searchParams.get('scope'));
	const tag = $derived(page.url.searchParams.get('tag'));

	// The rail's scope/tag picks the base set; the toolbar narrows within it.
	// A tag filter implies prompts (skills have no tags — see the spec).
	const scoped = $derived.by(() => {
		if (tag) {
			return libraryNav.all.filter(
				(item) => item.kind === 'prompt' && item.prompt.tags.some((t) => t.name === tag)
			);
		}
		if (scope === 'favorites') return libraryNav.favorites;
		if (scope === 'shared') return libraryNav.shared;
		if (scope === 'personal') return libraryNav.personal;
		return libraryNav.all;
	});

	const shown = $derived.by(() => {
		const filtered = scoped.filter((item) => {
			if (typeFilter === 'prompts' && item.kind !== 'prompt') return false;
			if (typeFilter === 'skills' && item.kind !== 'skill') return false;
			return itemMatches(item, query);
		});
		return [...filtered].sort((a, b) =>
			sort === 'name'
				? itemName(a).localeCompare(itemName(b))
				: itemUseCount(b) - itemUseCount(a)
		);
	});

	const heading = $derived(
		tag
			? `#${tag}`
			: scope === 'favorites'
				? 'Favorites'
				: scope === 'shared'
					? 'Shared'
					: scope === 'personal'
						? 'Personal'
						: 'All'
	);

	const filtering = $derived(query.trim() !== '' || typeFilter !== 'all');
	const rawTotal = $derived(libraryNav.all.length);
	const cols = $derived(compact ? '160px' : '220px');

	const cardHref = (item: LibraryItem) =>
		`${base}/library/${item.kind === 'prompt' ? 'prompts' : 'skills'}/${item.id}${page.url.search}`;

	async function toggleFavorite(item: LibraryItem) {
		if (item.kind === 'prompt') {
			if (item.prompt.isFavorited) {
				const favs = await myPromptFavorites();
				if (!favs.success) return;
				const fav = favs.data.find((entry) => entry.promptId === item.id);
				if (fav) await unfavoritePrompt(fav.id);
			} else {
				await favoritePrompt(item.id);
			}
		} else {
			if (itemIsFavorited(item)) {
				const favs = await mySkillFavorites();
				if (!favs.success) return;
				const fav = favs.data.find((entry) => entry.skillId === item.id);
				if (fav) await unfavoriteSkill(fav.id);
			} else {
				await favoriteSkill(item.id);
			}
		}
		libraryNav.refresh();
	}
</script>
```

Template: same skeleton as `prompt-gallery.svelte:102-213` with:

- Header: icon `LibraryBig`, `<h1>Library</h1>`, and a `New` dropdown button replacing the single New-prompt button:

```svelte
		<DropdownMenu.Root>
			<DropdownMenu.Trigger data-testid="gallery-new">
				{#snippet child({ props })}
					<Button {...props} size="sm"><Plus class="size-3.5" /> New</Button>
				{/snippet}
			</DropdownMenu.Trigger>
			<DropdownMenu.Content align="end">
				<DropdownMenu.Item
					data-testid="gallery-new-prompt"
					onSelect={() => (libraryNav.createPromptOpen = true)}
				>
					New prompt
				</DropdownMenu.Item>
				<DropdownMenu.Item
					data-testid="gallery-new-skill"
					onSelect={() => (libraryNav.createSkillOpen = true)}
				>
					New skill
				</DropdownMenu.Item>
				<DropdownMenu.Separator />
				<DropdownMenu.Item
					data-testid="gallery-import-skill"
					onSelect={() => (libraryNav.importOpen = true)}
				>
					<Download class="size-3.5" /> Import skill
				</DropdownMenu.Item>
			</DropdownMenu.Content>
		</DropdownMenu.Root>
```

- Toolbar: search input (`placeholder="Search library"`, `data-testid="gallery-search"`), the `TYPES` segmented control bound to `typeFilter`, sort `<select>` with `Most used` / `A-Z` options bound to `sort`.
- Grid: `{#each shown as item (item.kind + ':' + item.id)}` rendering `<LibraryCard {item} href={cardHref(item)} selected={item.id === selectedId} {compact} onToggleFavorite={toggleFavorite} />`.
- Loading guard `libraryNav.loading && rawTotal === 0`; whole-library empty state (`data-testid="gallery-empty"`) offering the same three New/Import actions; scope-empty paragraph (`data-testid="gallery-scope-empty"`) with per-scope copy as in the prompt gallery.
- NO dialog instances inside the gallery — dialogs are global in nav-pane (Task 11).

- [ ] **Step 3: Verify**

Run: `cd frontend && npm run check && npx vitest run`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/routes/library/components
git commit -m "feat(spa): merged library gallery + generic library card" -- frontend/src/routes/library/components
```

---

### Task 10: Frontend — `/library` routes (layout, page, readers)

**Files:**
- Create: `frontend/src/routes/library/+layout.svelte`
- Create: `frontend/src/routes/library/+page.svelte`
- Create: `frontend/src/routes/library/prompts/[promptId]/+page.svelte`
- Create: `frontend/src/routes/library/skills/[skillId]/+page.svelte`

**Interfaces:**
- Consumes: gallery (Task 9), dialogs (Tasks 7/8), `libraryNav`; the current detail pages `frontend/src/routes/prompts/[promptId]/+page.svelte` and `frontend/src/routes/skills/[skillId]/+page.svelte` (still present — port their READ view; their edit branches die).
- Produces: working `/library`, `/library/prompts/[id]`, `/library/skills/[id]` routes. Readers open the corresponding form dialog for Edit and honor `?edit=true`.

- [ ] **Step 1: Layout**

`frontend/src/routes/library/+layout.svelte` — port `routes/prompts/+layout.svelte` verbatim with:

- `import LibraryGallery from './components/library-gallery.svelte';`
- `const selectedId = $derived(page.params.promptId ?? page.params.skillId ?? null);`
- Mode sync sets `'library'` (`if (workbench.mode !== 'library') void workbench.setMode('library');`) — note: `'library'` exists in the union after Task 3.
- `<title>Magus — Library</title>`, root `data-testid="library-view"`, renders `<LibraryGallery {selectedId} compact={readerOpen} />`.
- Add the `?new=` handler (from the `/skills/new` redirect):

```ts
	let newParamApplied = false;
	$effect(() => {
		if (newParamApplied) return;
		const kind = page.url.searchParams.get('new');
		newParamApplied = true;
		if (kind === 'skill') libraryNav.createSkillOpen = true;
		if (kind === 'prompt') libraryNav.createPromptOpen = true;
		if (kind) {
			const url = new URL(page.url);
			url.searchParams.delete('new');
			void goto(`${url.pathname}${url.search}`, { replaceState: true });
		}
	});
```

`frontend/src/routes/library/+page.svelte`:

```svelte
<!-- Intentionally empty: the gallery renders in +layout.svelte so it stays
     mounted across /library <-> /library/*/[id] (master-detail parity with
     the old /prompts and /skills trees). -->
```

- [ ] **Step 2: Prompt reader**

`frontend/src/routes/library/prompts/[promptId]/+page.svelte` — copy `routes/prompts/[promptId]/+page.svelte` and apply:

1. Delete the whole editing branch (`{:else if editing}` block, lines 219-278) and the form state/functions: `editing`, `saving`, `saveError` stays (used by share/publish/delete errors), `name/content/description/additionalInformation/type` form fields, `syncForm`, `save`, `cancelEdit`, `canSave`.
2. Add `let editOpen = $state(false);` and render at the end of the file:

```svelte
<PromptFormDialog bind:open={editOpen} prompt={prompt} onSaved={(updated) => (prompt = updated)} />
```

with `import PromptFormDialog from '$lib/components/shell/prompt-form-dialog.svelte';`.
3. The `?edit=true` effect sets `editOpen = true` instead of `editing = true` (keep the one-shot `editParamApplied` guard, gated on `prompt` being loaded).
4. Edit button (`data-testid="prompt-edit"`) does `onclick={() => (editOpen = true)}`.
5. Replace every `promptsNav` use with `libraryNav` (import swap; `refresh()` calls stay).
6. Back button + post-delete navigation: `/prompts` → `/library` (keep `${page.url.search}` on the back href).
7. The `isNew` / `id === 'new'` branch: keep the guard but redirect to `${base}/library` (creation is dialog-only).
8. Everything else (favorite toggle, share, publish, use-prompt, tags, read-view markup) stays verbatim.

- [ ] **Step 3: Skill reader**

`frontend/src/routes/library/skills/[skillId]/+page.svelte` — copy `routes/skills/[skillId]/+page.svelte` and apply the same surgery:

1. Delete the create/edit branch (lines 241-328) and form state/helpers: `editing`, `name/displayName/description/body/requestedToolsRaw/nameError`, `NAME_RE`, `syncForm`, `validateName`, `parseTools`, `save`, `cancelEdit`, `canSave`. Keep `saving`? No — remove it too (only save used it); keep `saveError` (share/delete errors).
2. The `isNew` (`skillId === 'new'`) handling: replace with a redirect effect to `${base}/library?new=skill` (`{ replaceState: true }`).
3. Add `let editOpen = $state(false);`, render `<SkillFormDialog bind:open={editOpen} skill={skill} onSaved={(updated) => (skill = updated)} />`, import it.
4. Add the `?edit=true` one-shot effect (same pattern as the prompt reader) setting `editOpen = true`.
5. Edit button (`data-testid="skill-edit"`) opens the dialog.
6. `skillsNav` → `libraryNav`; back button + post-delete `/skills` → `/library`; keep `${page.url.search}` on back.
7. Read view (chips, tools, Markdown body, artifacts table, download link) stays verbatim.

- [ ] **Step 4: Verify**

Run: `cd frontend && npm run check && npx vitest run`
Expected: PASS. (Old routes still exist and still work; both trees compile.)

- [ ] **Step 5: Commit**

```bash
git add frontend/src/routes/library
git commit -m "feat(spa): /library route tree with master-detail readers" -- frontend/src/routes/library
```

---

### Task 11: Frontend — mode plumbing + nav-pane switch to Library

**Files:**
- Modify: `frontend/src/lib/components/shell/mode-strip.svelte`
- Modify: `frontend/src/lib/route-mode.ts`
- Create: `frontend/src/lib/route-mode.test.ts`
- Modify: `frontend/src/lib/stores/workbench.svelte.ts` (mode getter legacy mapping)
- Modify: `frontend/src/lib/components/shell/nav-pane.svelte`
- Modify: `frontend/src/lib/components/shell/skill-import-dialog.svelte` (store swap)

**Interfaces:**
- Consumes: `'library'` mode value (Task 3), `LibraryNav` rail (Task 6), dialogs (Tasks 7/8).
- Produces: mode strip shows Chat, Brain, Files, Library, Agents; `modeFromPath` maps `/library`, `/prompts`, `/skills` → `'library'`; `workbench.mode` maps legacy session values `'prompts'`/`'skills'` → `'library'`; nav-pane `library` branch with a `New` dropdown (New prompt / New skill / Import skill) and globally-rendered `PromptFormDialog` + `SkillFormDialog` + `SkillImportDialog`.

- [ ] **Step 1: Write the failing route-mode test**

`frontend/src/lib/route-mode.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { modeFromPath } from './route-mode';

describe('modeFromPath', () => {
	it('maps /library to library', () => {
		expect(modeFromPath('/library')).toBe('library');
		expect(modeFromPath('/library/prompts/abc')).toBe('library');
		expect(modeFromPath('/library/skills/abc')).toBe('library');
	});

	it('maps legacy /prompts and /skills paths to library', () => {
		expect(modeFromPath('/prompts')).toBe('library');
		expect(modeFromPath('/prompts/abc')).toBe('library');
		expect(modeFromPath('/skills/abc')).toBe('library');
	});

	it('keeps the other modes', () => {
		expect(modeFromPath('/brain/x')).toBe('brain');
		expect(modeFromPath('/files')).toBe('files');
		expect(modeFromPath('/agents/a1')).toBe('agents');
		expect(modeFromPath('/settings')).toBe('chat');
	});
});
```

Run: `cd frontend && npx vitest run src/lib/route-mode.test.ts` — Expected: FAIL (`'prompts'` returned).

- [ ] **Step 2: Update `route-mode.ts`**

```ts
const MODE_SEGMENTS: Array<[Mode, string]> = [
	['brain', '/brain'],
	['files', '/files'],
	['library', '/library'],
	// Legacy trees redirect to /library; don't flash the chat nav meanwhile.
	['library', '/prompts'],
	['library', '/skills'],
	['agents', '/agents']
];
```

Run the test again — Expected: PASS.

- [ ] **Step 3: `workbench.svelte.ts` mode getter**

Replace the getter body (line 115-121):

```ts
	get mode(): WorkbenchMode {
		if (this.session) {
			const mode = this.session.mode;
			// Saved sessions may still hold the pre-merge modes.
			return mode === 'prompts' || mode === 'skills' ? 'library' : mode;
		}
		// Pre-session fallback: reloading on /brain/... must not flash the
		// chat nav while the TabSession round trip is in flight.
		if (typeof location !== 'undefined') return modeFromPath(location.pathname);
		return 'chat';
	}
```

- [ ] **Step 4: `mode-strip.svelte`**

- Import `LibraryBig` from `@lucide/svelte` (drop `ScrollText`/`Boxes` if now unused).
- `modes` array (line 30-37): remove the `prompts` and `skills` entries; insert `{ key: 'library', label: 'Library', icon: LibraryBig }` after `files`.
- `MODE_HOME` (line 39-46): `Record<WorkbenchMode, string>` still needs every union key; set `prompts: '/library'`, `skills: '/library'`, add `library: '/library'`.
- `selectMode` regex (line 55): `/^\/(chat|brain|files|library|agents|prompts|skills)(\/|$)/`.

- [ ] **Step 5: `nav-pane.svelte`**

- Imports: drop `PromptsNav`, `SkillsNav`, `skillsNav`; add `LibraryNav` (`./library-nav.svelte`), `libraryNav` (`$lib/stores/library-nav.svelte`), `PromptFormDialog`, `SkillFormDialog`, `DropdownMenu` (`$lib/components/ui/dropdown-menu`).
- Replace the whole `workbench.mode === 'skills'` primary-action branch AND the `'prompts'` `{:else if}` clause with one `library` branch (keep chat/brain/files/agents clauses as they are). The library branch is a `New` dropdown:

```svelte
					{#if workbench.mode === 'library'}
						<Sidebar.MenuItem>
							<DropdownMenu.Root>
								<DropdownMenu.Trigger>
									{#snippet child({ props })}
										<Sidebar.MenuButton {...props} data-testid="library-new">
											<Plus class="text-muted-foreground" />
											<span>New</span>
										</Sidebar.MenuButton>
									{/snippet}
								</DropdownMenu.Trigger>
								<DropdownMenu.Content align="start" class="w-48">
									<DropdownMenu.Item
										data-testid="library-new-prompt"
										onSelect={() => (libraryNav.createPromptOpen = true)}
									>
										New prompt
									</DropdownMenu.Item>
									<DropdownMenu.Item
										data-testid="library-new-skill"
										onSelect={() => (libraryNav.createSkillOpen = true)}
									>
										New skill
									</DropdownMenu.Item>
									<DropdownMenu.Separator />
									<DropdownMenu.Item
										data-testid="library-import-skill"
										onSelect={() => (libraryNav.importOpen = true)}
									>
										<Download class="size-4" /> Import skill
									</DropdownMenu.Item>
								</DropdownMenu.Content>
							</DropdownMenu.Root>
						</Sidebar.MenuItem>
					{:else if ...}
```

(Structure note: today `'skills'` is a top-level `{#if}` with the rest in `{:else}` — collapse that so all modes live in one `{#if}/{:else if}` chain.)
- Rail content: replace the `'prompts'`/`'skills'` clauses with `{:else if workbench.mode === 'library'}<LibraryNav />`.
- Remove the Task 7 interim `promptFormOpen` local state; global dialogs at the end of the file (after `<SkillImportDialog />`):

```svelte
<PromptFormDialog bind:open={libraryNav.createPromptOpen} />
<SkillFormDialog bind:open={libraryNav.createSkillOpen} />
```

(`bind:` to store class fields works in Svelte 5; if the compiler rejects it, use explicit `open={...} onOpenChange={...}` — check how `SkillImportDialog` binds `skillsNav.importOpen` today and mirror that mechanism.)

- [ ] **Step 6: `skill-import-dialog.svelte`**

Swap `skillsNav` → `libraryNav` (import + every reference: `importOpen`, `refresh()`), and update any post-import navigation from `/skills/...` to `/library/skills/...`. Read the file first.

- [ ] **Step 7: Verify**

Run: `cd frontend && npm run check && npx vitest run`
Expected: PASS. Old `/prompts`+`/skills` routes still compile (their galleries still reference their own stores — untouched; deleted next task).

- [ ] **Step 8: Commit**

```bash
git add frontend/src/lib/components/shell frontend/src/lib/route-mode.ts frontend/src/lib/route-mode.test.ts frontend/src/lib/stores/workbench.svelte.ts
git commit -m "feat(spa): Library mode replaces Prompts+Skills in shell (strip, nav pane, route inference)" -- frontend/src/lib/components/shell frontend/src/lib/route-mode.ts frontend/src/lib/route-mode.test.ts frontend/src/lib/stores/workbench.svelte.ts
```

---

### Task 12: Frontend — redirects, search links, delete the old trees

**Files:**
- Create: `frontend/src/routes/prompts/+page.ts`, `frontend/src/routes/prompts/[promptId]/+page.ts`
- Create: `frontend/src/routes/skills/+page.ts`, `frontend/src/routes/skills/[skillId]/+page.ts`
- Delete: `frontend/src/routes/prompts/+layout.svelte`, `frontend/src/routes/prompts/+page.svelte`, `frontend/src/routes/prompts/[promptId]/+page.svelte`, `frontend/src/routes/prompts/components/` (gallery + card)
- Delete: `frontend/src/routes/skills/+layout.svelte`, `frontend/src/routes/skills/+page.svelte`, `frontend/src/routes/skills/[skillId]/+page.svelte`, `frontend/src/routes/skills/components/`
- Delete: `frontend/src/lib/stores/prompts-nav.svelte.ts`, `frontend/src/lib/stores/skills-nav.svelte.ts`, `frontend/src/lib/stores/skills-nav.test.ts`, `frontend/src/lib/components/shell/prompts-nav.svelte`, `frontend/src/lib/components/shell/skills-nav.svelte`
- Modify: `frontend/src/routes/search/+page.svelte`

**Interfaces:**
- Consumes: `/library` tree (Task 10). Produces: legacy URLs redirect; skills appear in the search page; zero references to the deleted modules remain.

- [ ] **Step 1: Redirect stubs**

`frontend/src/routes/prompts/+page.ts`:

```ts
import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';

export const load = () => {
	redirect(307, `${base}/library?type=prompts`);
};
```

`frontend/src/routes/prompts/[promptId]/+page.ts`:

```ts
import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';
import type { PageLoad } from './$types';

export const load: PageLoad = ({ params, url }) => {
	redirect(307, `${base}/library/prompts/${params.promptId}${url.search}`);
};
```

`frontend/src/routes/skills/+page.ts`:

```ts
import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';

export const load = () => {
	redirect(307, `${base}/library?type=skills`);
};
```

`frontend/src/routes/skills/[skillId]/+page.ts` (`new` was a real route value here):

```ts
import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';
import type { PageLoad } from './$types';

export const load: PageLoad = ({ params, url }) => {
	if (params.skillId === 'new') redirect(307, `${base}/library?new=skill`);
	redirect(307, `${base}/library/skills/${params.skillId}${url.search}`);
};
```

- [ ] **Step 2: Delete the old implementation files**

`git rm` every file in the Delete list above (the `+page.svelte`/`+layout.svelte` files must go so the stubs' redirects are the only handlers). Then grep to prove nothing references them:

```bash
rg -l "prompts-nav|skills-nav|prompt-gallery|skill-gallery|prompt-card|skill-card|routes/prompts/components|routes/skills/components" frontend/src
```

Expected: no matches (or only `library-nav` false-positives — inspect any hit).

- [ ] **Step 3: Search page**

In `frontend/src/routes/search/+page.svelte`:

- `TABS`: add `{ id: 'skill', label: 'Skills' }` after the prompts entry.
- `TYPE_META`: add `skill: { label: 'Skill', icon: BookMarked }` (import `BookMarked`).
- The `href` switch (line ~83-89): change `case 'prompt'` to return `` `${base}/library/prompts/${result.id}` `` and add `case 'skill': return `${base}/library/skills/${result.id}`;`.
- Update the placeholder/description copy to mention skills (e.g. "Search messages, conversations, prompts, skills, files…").

- [ ] **Step 4: Verify**

Run: `cd frontend && npm run check && npx vitest run && npm run build`
Expected: all PASS (the build catches route-level breakage that svelte-check misses).

- [ ] **Step 5: Commit**

```bash
git add -A frontend/src/routes/prompts frontend/src/routes/skills frontend/src/routes/search frontend/src/lib/stores frontend/src/lib/components/shell
git commit -m "feat(spa): legacy /prompts + /skills redirect to /library; skills in search; drop mirrored components" -- frontend/src/routes frontend/src/lib/stores frontend/src/lib/components/shell
```

---

### Task 13: Full verification sweep

**Files:** none new.

- [ ] **Step 1: Backend suite + warnings**

```bash
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors && MIX_ENV=test mix test
```

Expected: clean compile, full suite green (pre-existing flakes noted in memory: super-brain shared-DB leaks — rerun any such failure once before investigating).

- [ ] **Step 2: Frontend suite**

```bash
cd frontend && npm run check && npx vitest run && npm run build
```

Expected: all green.

- [ ] **Step 3: `mix precommit`**

```bash
set -a && source .env && set +a && mix precommit
```

Expected: PASS (includes format + unused deps checks). Commit any formatter fallout:

```bash
git add -A && git commit -m "chore: formatter + precommit fixes for library view merge" || true
```

- [ ] **Step 4: Manual smoke list (report, don't skip)**

Boot `mix phx.server` in the worktree (pick a free port via `PORT=4002` if 4000 is taken) and verify in the browser (or report the checklist as not-run if no browser access):

1. `/library` shows the mixed grid; type filter + sort work.
2. Mode strip shows Library (no Prompts/Skills); clicking it navigates.
3. New dropdown: create a prompt via modal (type dropdown user/system present); create a skill via modal; import dialog opens.
4. Open a prompt reader → Edit opens the modal; save reflects in the reader. Same for a skill.
5. Favorite a skill from a card; it appears under the Favorites scope.
6. `/prompts`, `/prompts/<id>`, `/skills`, `/skills/<id>`, `/skills/new` all redirect correctly.
7. Global search returns a skill and links into `/library/skills/<id>`.

---

## Self-review checklist (run after writing, fixed inline)

- Spec coverage: mixed grid (T9), type badges (T9), favorites+search parity (T1/T2/T4), no built-ins (nowhere added), New dropdown (T9/T11), modals for create+edit incl. prompt type dropdown (T7/T8/T10), unified route tree + redirects (T10/T12), mode plumbing + legacy session mapping (T3/T11), store/rail merge (T6), cleanup (T12), tests (T1/T2/T3/T5/T11).
- Placeholders: none — every step has code or an exact-anchor port instruction against a file that still exists at that point in the sequence.
- Type consistency: `libraryNav` fields (`all/favorites/shared/personal/loading/importOpen/createPromptOpen/createSkillOpen`), `LibraryItem` helpers, RPC wrapper names (`myFavoriteSkills`, `mySkillFavorites`, `favoriteSkill`, `unfavoriteSkill`) are used with the same names in Tasks 4-12.
