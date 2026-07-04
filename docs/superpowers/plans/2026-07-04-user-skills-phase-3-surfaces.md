# User Skills Phase 3 (Surfaces) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users edit a skill's bundle files in the browser and publish/browse/copy skills through a public marketplace.

**Architecture:** The file-tree editor composes existing pieces (`Import.Unpack` + `Export.generate_bundle` from Plan 2B) behind one `update_skill_file` action that re-packs the bundle and recomputes `bundle_sha` (which re-gates approvals via Plan 2A). The marketplace copies the public-visibility pattern from `Magus.Library.Prompt` onto `Skill` (`is_public`, `publish`/`unpublish`, `public_skills` read, a copy-to-library action that clones via Export to Import), plus an SPA gallery.

**Tech Stack:** Elixir, Ash 3.x, SvelteKit 5 + AshTypescript RPC. The in-browser file editor uses a monospace `<textarea>` (see Deviation below), not a rich-text or code-editor library.

## Deviation from the spec (recorded)

The design doc (2026-07-04) said the editor would reuse "CodeMirror, already shipped with the SPA via Brain." That is incorrect: the SPA's Brain editor is **Tiptap** (a ProseMirror rich-text editor), which is wrong for editing source files, and **CodeMirror is not a dependency**. This plan uses a plain monospace `<textarea>` for file editing (zero new dependencies, YAGNI). Syntax highlighting is a later enhancement (swap the textarea for CodeMirror 6 if desired) and is out of scope. No behavior in the plan depends on the editor widget beyond "read text, edit text, save text."

## Global Constraints

- **No em dashes** in written content. Use colons/periods/commas.
- **Never run `mix ash.reset`**. Use `mix ash.codegen <name>` then `mix ash.migrate`.
- **Depends on Plan 2A** (`Skill.bundle_sha`, `ConversationSkillApproval`, `SkillTrust`) and **Plan 2B** (`Magus.Skills.Export.generate_bundle/1`, `Import.Unpack`, `Import.import_bundle/2`).
- **Editing a bundle recomputes `bundle_sha`**, which re-gates conversation approvals and stales trust grants (this is intended: new content needs new consent). Do not bypass it.
- **Marketplace safety**: a public skill is still sandbox-isolated and still hits the first-run approval gate + declared-secret disclosure. Copies arrive un-approved and un-trusted. Admin can unpublish.
- **Editor size cap**: text files editable in-browser only under 256 KB; binaries and oversized files are download-only.
- **Frontend tests stay structural** (`data-testid` + counts).
- **CI compiles with `--warnings-as-errors`**: run `MIX_ENV=test mix compile --warnings-as-errors` per task.
- **Regenerate RPC types** with `mix ash_typescript.codegen` off-server after Ash RPC changes; generated files are never hand-edited.

---

## File Structure

Modified backend:
- `lib/magus/skills/skill.ex` — `is_public` + `published_at` attributes; `publish`/`unpublish`/`unpublish_as_admin` actions; `public_skills`/`public_search` reads; `copy_to_library` action; `update_file` action; policy `extra_read` for public
- `lib/magus/skills/skills.ex` — register the new RPC actions + code interfaces
- `lib/magus/skills/file_edit.ex` (new) — the re-pack-a-single-file logic used by `update_file`

New/modified frontend:
- `frontend/src/routes/library/skills/[skillId]/+page.svelte` — file tree + inline editor; publish toggle; Public badge
- `frontend/src/routes/library/skills/explore/+page.svelte` (new) — public gallery + copy
- `frontend/src/lib/ash/api.ts` — publish/unpublish/copy/public-search + file read/write wrappers

Migration:
- one structural migration for `is_public` + `published_at`

---

## Task 1: Public visibility on `Skill` (attributes, actions, policy)

**Files:**
- Modify: `lib/magus/skills/skill.ex`
- Modify: `lib/magus/skills/skills.ex`
- Create (generated): migration
- Test: `test/magus/skills/skill_public_test.exs`

**Interfaces:**
- Produces: `Skill.is_public`, `Skill.published_at`; actions `:publish`, `:unpublish`, `:public_skills`, `:public_search`; code interfaces `publish_skill/1`, `unpublish_skill/1`, `public_skills/0`, `public_search_skills/1`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/skill_public_test.exs
defmodule Magus.Skills.SkillPublicTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "publish makes a skill visible in public_skills; unpublish removes it" do
    author = generate(user())
    reader = generate(user())

    {:ok, skill} = Magus.Skills.create_skill(%{name: "pub-skill", description: "d", body: "b"}, actor: author)

    # Not public yet: a different user cannot see it via public read.
    assert Magus.Skills.public_skills!(authorize?: false) |> Enum.all?(&(&1.id != skill.id))

    {:ok, published} = Magus.Skills.publish_skill(skill, actor: author)
    assert published.is_public == true
    assert published.published_at != nil

    ids = Magus.Skills.public_skills!(authorize?: false) |> Enum.map(& &1.id)
    assert skill.id in ids

    # A reader (not the author) can read the published skill via policy.
    assert {:ok, _} = Magus.Skills.get_skill(skill.id, actor: reader)

    {:ok, _} = Magus.Skills.unpublish_skill(published, actor: author)
    ids2 = Magus.Skills.public_skills!(authorize?: false) |> Enum.map(& &1.id)
    refute skill.id in ids2
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/skill_public_test.exs`
Expected: FAIL (`publish_skill/1`, `public_skills/0`, `is_public` undefined).

- [ ] **Step 3: Add attributes**

In `lib/magus/skills/skill.ex` `attributes do`:

```elixir
    attribute :is_public, :boolean do
      default false
      allow_nil? false
      public? true
      description "Whether the skill is published to the public marketplace"
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the skill was published"
    end
```

- [ ] **Step 4: Add actions**

In `actions do`:

```elixir
    read :public_skills do
      filter expr(is_public == true)
    end

    read :public_search do
      argument :query, :string, allow_nil?: true

      argument :sort_by, :atom do
        constraints one_of: [:recent, :name]
        default :recent
      end

      filter expr(is_public == true)

      prepare fn query, _context ->
        require Ash.Query

        query =
          case Ash.Query.get_argument(query, :query) do
            q when q in [nil, ""] -> query
            term -> Ash.Query.filter(query, contains(name, ^term) or contains(description, ^term))
          end

        case Ash.Query.get_argument(query, :sort_by) do
          :name -> Ash.Query.sort(query, name: :asc)
          _ -> Ash.Query.sort(query, published_at: :desc)
        end
      end
    end

    update :publish do
      require_atomic? false
      accept []

      change set_attribute(:is_public, true)

      change fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :published_at, DateTime.utc_now())
      end
    end

    update :unpublish do
      require_atomic? false
      accept []
      change set_attribute(:is_public, false)
    end

    update :unpublish_as_admin do
      require_atomic? false
      accept []
      change set_attribute(:is_public, false)
    end
```

- [ ] **Step 5: Extend the policy for public reads + admin unpublish**

In `policies do`, add `extra_read` and an admin policy. The existing block uses `workspace_scoped_policies(resource_type: :skill)`; add the public read like Prompt does:

```elixir
  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(
      resource_type: :skill,
      extra_read: [
        quote do
          authorize_if expr(is_public == true)
        end
      ]
    )

    policy action(:unpublish_as_admin) do
      authorize_if Magus.Checks.IsAdmin
    end
  end
```

- [ ] **Step 6: Register code interfaces + RPC**

In `lib/magus/skills/skills.ex` `resources do` (Skill block), add:

```elixir
      define :publish_skill, action: :publish
      define :unpublish_skill, action: :unpublish
      define :unpublish_skill_as_admin, action: :unpublish_as_admin
      define :public_skills, action: :public_skills
      define :public_search_skills, action: :public_search, args: []
```

In `typescript_rpc do` (Skill block):

```elixir
      rpc_action :publish_skill, :publish
      rpc_action :unpublish_skill, :unpublish
      rpc_action :public_skills, :public_skills
      rpc_action :public_search_skills, :public_search
```

- [ ] **Step 7: Migration + tests + compile**

Run: `mix ash.codegen add_skill_public_visibility && mix ash.migrate`
Run: `mix test test/magus/skills/skill_public_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/skills/skill.ex lib/magus/skills/skills.ex priv/repo/migrations test/magus/skills/skill_public_test.exs
git commit -m "feat(skills): public visibility on Skill (publish/unpublish, public reads, admin unpublish)"
```

---

## Task 2: Copy-to-library (clone a public skill)

**Files:**
- Modify: `lib/magus/skills/skill.ex` (`copy_to_library` create action)
- Modify: `lib/magus/skills/skills.ex` (interface + RPC)
- Test: `test/magus/skills/skill_copy_test.exs`

**Interfaces:**
- Consumes: `Magus.Skills.Export.generate_bundle/1` + `Import.import_bundle/2` (Plan 2B) for a fully-owned snapshot.
- Produces: `Magus.Skills.copy_skill_to_library/1` cloning a public skill for the actor.

The copy is a snapshot via Export to Import, so the copied skill owns its own bundle blob (no shared reference to the source) and arrives un-approved/un-trusted.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/skill_copy_test.exs
defmodule Magus.Skills.SkillCopyTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "copying a public bundled skill yields an owned snapshot" do
    author = generate(user())
    copier = generate(user())

    bytes =
      build_zip([{"SKILL.md", "---\nname: shared-skill\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])

    {:ok, source} = Magus.Skills.Import.import_bundle(bytes, actor: author)
    {:ok, _} = Magus.Skills.publish_skill(source, actor: author)

    {:ok, copy} = Magus.Skills.copy_skill_to_library(%{source_skill_id: source.id}, actor: copier)

    assert copy.id != source.id
    assert copy.user_id == copier.id
    assert copy.name == "shared-skill"
    assert copy.has_executable_bundle
    assert copy.is_public == false
    # Owns its own content-addressed blob (same sha since identical content).
    assert copy.bundle_sha == source.bundle_sha
    assert {:ok, _} = Magus.Files.Storage.get(copy.bundle_path)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/skill_copy_test.exs`
Expected: FAIL (`copy_skill_to_library/1` undefined).

- [ ] **Step 3: Implement copy as a domain function**

Copy is naturally a two-step (export the source, import as the actor), which does not fit a single Ash action cleanly. Implement it as a domain function in `lib/magus/skills/skills.ex`:

```elixir
  @doc """
  Clone a public skill into the actor's library as a fully-owned snapshot.
  Exports the source bundle and re-imports it as the actor, so the copy owns its
  own blob and arrives un-approved/un-trusted. `source_skill_id` must be public
  (or otherwise readable by the actor).
  """
  def copy_skill_to_library(%{source_skill_id: source_id}, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, source} <- Magus.Skills.get_skill(source_id, actor: actor),
         true <- source.is_public || {:error, :not_public},
         {:ok, zip} <- Magus.Skills.Export.generate_bundle(source),
         {:ok, copy} <- Magus.Skills.Import.import_bundle(zip, actor: actor) do
      # Record provenance without leaking the source's public flag.
      Magus.Skills.update_skill(copy, %{source_url: "skill:#{source.id}"}, actor: actor)
    else
      false -> {:error, :not_public}
      other -> other
    end
  end
```

> `update_skill`'s `:update` accept list includes `source_url` already? Check: the recon shows `:update` accepts name/display_name/description/body/requested_tools/required_secrets/runtime_hints/metadata/version/license/compatibility/icon/color. It does NOT include `source_url`. Add `:source_url` to the `:update` accept list (one-line change in `skill.ex`), or drop the provenance write. Prefer adding `:source_url` so copies record their origin.

Add `:source_url` to the `:update` action accept list in `lib/magus/skills/skill.ex`.

Expose via the domain (`resources do`, but it is a plain function so add to `typescript_rpc` only if the SPA calls it directly; simpler to expose a controller-free RPC through a create-style action). For the SPA, add a thin RPC by wrapping in a generic action is awkward; instead expose it through a small RPC controller OR call it from a create action. **Chosen approach:** expose a dedicated RPC via a resource action is not possible for a 2-step flow, so add an `api.ts` wrapper that POSTs to a tiny controller.

Create `lib/magus_web/rpc/skill_copy_controller.ex`:

```elixir
defmodule MagusWeb.Rpc.SkillCopyController do
  use MagusWeb, :controller

  def create(conn, %{"source_skill_id" => source_id}) do
    user = conn.assigns.current_user

    case Magus.Skills.copy_skill_to_library(%{source_skill_id: source_id}, actor: user) do
      {:ok, skill} -> json(conn, %{success: true, data: %{id: skill.id, name: skill.name}})
      {:error, reason} -> json(conn, %{success: false, errors: [%{type: "copy_failed", message: "#{inspect(reason)}", shortMessage: "Copy failed", vars: %{}, fields: [], path: []}]})
    end
  end
end
```

Route it in the `:rpc` pipeline scope (next to the skills import route): `post "/rpc/skills/copy", Rpc.SkillCopyController, :create`.

- [ ] **Step 4: Run test + compile**

Run: `mix test test/magus/skills/skill_copy_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/skills.ex lib/magus/skills/skill.ex lib/magus_web/rpc/skill_copy_controller.ex lib/magus_web/router.ex test/magus/skills/skill_copy_test.exs
git commit -m "feat(skills): copy a public skill into your library as an owned snapshot"
```

---

## Task 3: `update_file` (edit one bundle file, re-pack, re-sha)

**Files:**
- Create: `lib/magus/skills/file_edit.ex`
- Modify: `lib/magus/skills/skills.ex` (code interface `update_skill_file`)
- Test: `test/magus/skills/file_edit_test.exs`

**Interfaces:**
- Consumes: `Import.Unpack.unpack/1`, `Export`/`:zip` for re-pack, `Magus.Files.Storage.store/2`.
- Produces: `Magus.Skills.update_skill_file(skill, path, content, actor)` -> updated skill with new `bundle_path`, `bundle_sha`, `bundle_byte_size`, `file_manifest`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/file_edit_test.exs
defmodule Magus.Skills.FileEditTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "editing a bundle file re-packs and changes bundle_sha" do
    user = generate(user())

    bytes =
      build_zip([{"SKILL.md", "---\nname: edit-skill\ndescription: d\n---\nb"}, {"scripts/go.py", "print(1)"}])

    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    old_sha = skill.bundle_sha

    {:ok, updated} =
      Magus.Skills.update_skill_file(skill, "scripts/go.py", "print(2)", actor: user)

    refute updated.bundle_sha == old_sha

    {:ok, zip} = Magus.Files.Storage.get(updated.bundle_path)
    {:ok, %{files: files}} = Magus.Skills.Import.Unpack.unpack(zip)
    assert {"scripts/go.py", "print(2)"} in files
  end

  test "rejects an unsafe path" do
    user = generate(user())
    bytes = build_zip([{"SKILL.md", "---\nname: e2\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)

    assert {:error, :unsafe_path} = Magus.Skills.update_skill_file(skill, "../evil", "x", actor: user)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/file_edit_test.exs`
Expected: FAIL (`update_skill_file/4` undefined).

- [ ] **Step 3: Implement the file-edit re-pack**

```elixir
# lib/magus/skills/file_edit.ex
defmodule Magus.Skills.FileEdit do
  @moduledoc """
  Replace a single file inside a skill's bundle: unpack, swap the file, re-pack,
  store the new content-addressed blob, and update the Skill's bundle metadata.
  The new bundle_sha re-gates conversation approvals (Plan 2A) automatically.

  SKILL.md is not edited here (it is authored through the structured fields);
  attempts to write it are rejected so the fields and the file cannot diverge.
  """

  alias Magus.Skills.Import.Unpack

  @spec update_file(map(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_file(skill, path, content, opts) do
    actor = Keyword.fetch!(opts, :actor)

    cond do
      path == "SKILL.md" ->
        {:error, :edit_skill_md_via_fields}

      unsafe?(path) ->
        {:error, :unsafe_path}

      is_nil(skill.bundle_path) ->
        {:error, :no_bundle}

      true ->
        do_update(skill, path, content, actor)
    end
  end

  defp do_update(skill, path, content, actor) do
    with {:ok, bytes} <- Magus.Files.Storage.get(skill.bundle_path),
         {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(bytes) do
      updated_files =
        files
        |> Enum.reject(fn {p, _} -> p == path end)
        |> Kernel.++([{path, content}])

      entries =
        [{~c"SKILL.md", md} | Enum.map(updated_files, fn {p, c} -> {String.to_charlist(p), c} end)]

      {:ok, {_n, new_zip}} = :zip.create(~c"skill.zip", entries, [:memory])

      sha = :crypto.hash(:sha256, new_zip) |> Base.encode16(case: :lower)
      new_path = "skills/#{skill.user_id}/#{sha}.zip"

      manifest =
        Enum.map(updated_files, fn {p, c} ->
          %{
            "path" => p,
            "size" => byte_size(c),
            "sha256" => :crypto.hash(:sha256, c) |> Base.encode16(case: :lower),
            "executable" => String.starts_with?(p, "scripts/")
          }
        end)

      with {:ok, _} <- Magus.Files.Storage.store(new_path, new_zip) do
        Magus.Skills.update_skill_bundle(
          skill,
          %{
            bundle_path: new_path,
            bundle_sha: sha,
            bundle_byte_size: byte_size(new_zip),
            file_manifest: manifest,
            has_executable_bundle: Enum.any?(updated_files, fn {p, _} -> String.starts_with?(p, "scripts/") end)
          },
          actor: actor
        )
      end
    end
  end

  # Reuse the same traversal rule as Unpack.
  defp unsafe?(path) do
    base = Path.expand("/__skill_base__")
    full = Path.expand(Path.join(base, path))

    String.starts_with?(path, "/") or
      Enum.any?(Path.split(path), &(&1 in [".", ".."])) or
      not (full == base or String.starts_with?(full, base <> "/"))
  end
end
```

- [ ] **Step 4: Add the bundle-update action + interfaces**

`Skill`'s `:update` action does not accept bundle fields (they are on `:import`). Add a dedicated `:update_bundle` action in `lib/magus/skills/skill.ex`:

```elixir
    update :update_bundle do
      require_atomic? false
      accept [:bundle_path, :bundle_sha, :bundle_byte_size, :file_manifest, :has_executable_bundle]
    end
```

In `lib/magus/skills/skills.ex` `resources do` (Skill block):

```elixir
      define :update_skill_bundle, action: :update_bundle
```

Add the public domain function that wraps `FileEdit`:

```elixir
  @doc "Edit one file inside a skill's bundle, re-packing and re-hashing."
  def update_skill_file(skill, path, content, opts),
    do: Magus.Skills.FileEdit.update_file(skill, path, content, opts)
```

Expose `update_skill_file` and a file-read to the SPA via a small controller (bundle file contents are not an Ash attribute). Create `lib/magus_web/rpc/skill_file_controller.ex`:

```elixir
defmodule MagusWeb.Rpc.SkillFileController do
  use MagusWeb, :controller

  alias Magus.Skills.Import.Unpack

  # GET /rpc/skills/:id/file?path=scripts/go.py
  def show(conn, %{"id" => id, "path" => path}) do
    user = conn.assigns.current_user

    with {:ok, skill} <- Magus.Skills.get_skill(id, actor: user),
         p when is_binary(p) <- skill.bundle_path,
         {:ok, bytes} <- Magus.Files.Storage.get(p),
         {:ok, %{files: files}} <- Unpack.unpack(bytes),
         {^path, content} <- Enum.find(files, fn {fp, _} -> fp == path end) || {:error, :not_found} do
      json(conn, %{success: true, data: %{path: path, content: content}})
    else
      _ -> conn |> put_status(:not_found) |> json(%{success: false, errors: [%{message: "file not found"}]})
    end
  end

  # POST /rpc/skills/:id/file  { path, content }
  def update(conn, %{"id" => id, "path" => path, "content" => content}) do
    user = conn.assigns.current_user

    with {:ok, skill} <- Magus.Skills.get_skill(id, actor: user),
         {:ok, updated} <- Magus.Skills.update_skill_file(skill, path, content, actor: user) do
      json(conn, %{success: true, data: %{id: updated.id, bundleSha: updated.bundle_sha}})
    else
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{success: false, errors: [%{message: "#{inspect(reason)}"}]})
    end
  end
end
```

Route both in the `:rpc` scope: `get "/rpc/skills/:id/file", ...` and `post "/rpc/skills/:id/file", ...`.

- [ ] **Step 5: Run tests + compile**

Run: `mix test test/magus/skills/file_edit_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/skills/file_edit.ex lib/magus/skills/skill.ex lib/magus/skills/skills.ex lib/magus_web/rpc/skill_file_controller.ex lib/magus_web/router.ex test/magus/skills/file_edit_test.exs
git commit -m "feat(skills): edit a bundle file in place (re-pack, re-sha, re-gate)"
```

---

## Task 4: File-tree editor UI (skill detail)

**Files:**
- Modify: `frontend/src/routes/library/skills/[skillId]/+page.svelte` (and/or the `/skills/[skillId]` detail; use the one that renders the artifacts table)
- Modify: `frontend/src/lib/ash/api.ts` (file read/write wrappers)
- Test: `frontend/tests/skills-file-editor.spec.ts`

**Interfaces:**
- Consumes: the `GET/POST /rpc/skills/:id/file` endpoints (Task 3), `skill.fileManifest` (existing).
- Produces: a file tree + inline editor on the detail page.

- [ ] **Step 1: Add api.ts wrappers**

```typescript
// frontend/src/lib/ash/api.ts
export function readSkillFile(id: string, path: string): Promise<RpcResult<{ path: string; content: string }>> {
	return rawGet(`/rpc/skills/${id}/file?path=${encodeURIComponent(path)}`);
}

export function writeSkillFile(id: string, path: string, content: string): Promise<RpcResult<{ id: string; bundleSha: string }>> {
	return rawPost(`/rpc/skills/${id}/file`, { path, content });
}
```

> `rawGet`/`rawPost` are thin `fetch` helpers returning `RpcResult`; if the file lacks them, mirror the `uploadSkillBundle` fetch+envelope pattern (credentials: 'same-origin', 401 -> UNAUTHENTICATED, JSON body). Add them once and reuse.

- [ ] **Step 2: Render the tree + editor**

In the skill detail component, keep the existing artifacts table but make each row (from `skill.fileManifest`) selectable. On selecting a text file under 256 KB, `readSkillFile` and show its content in a monospace `<textarea>` with a Save button. On Save, `writeSkillFile` and refresh the skill (so `fileManifest`/`bundleSha` update). SKILL.md is shown read-only with an "Edit as form" link to the existing structured editor (the `skill-edit` dialog).

```svelte
<!-- new state -->
let selectedPath = $state<string | null>(null);
let fileContent = $state('');
let saving = $state(false);

async function openFile(path: string, size: number) {
	if (path === 'SKILL.md') return; // edited via the form
	if (size > 256 * 1024) return;    // download-only
	const r = await readSkillFile(skill.id, path);
	if (r.success) { selectedPath = path; fileContent = r.data.content; }
}

async function saveFile() {
	if (!selectedPath) return;
	saving = true;
	const r = await writeSkillFile(skill.id, selectedPath, fileContent);
	saving = false;
	if (r.success) { const fresh = await getSkill(skill.id); if (fresh.success) skill = fresh.data; }
}
```

```svelte
<!-- in the artifacts table row, make the path a button -->
<button type="button" data-testid="skill-file-open" onclick={() => openFile(entry.path, Number(entry.size) || 0)}>
	{entry.path}
</button>

{#if selectedPath}
	<div class="mt-3" data-testid="skill-file-editor">
		<div class="mb-1 flex items-center justify-between">
			<span class="font-mono text-xs">{selectedPath}</span>
			<button class="wb-pill-btn text-xs" data-testid="skill-file-save" disabled={saving} onclick={() => void saveFile()}>
				{saving ? 'Saving…' : 'Save'}
			</button>
		</div>
		<textarea class="h-64 w-full rounded border border-input bg-background p-2 font-mono text-xs" bind:value={fileContent}></textarea>
	</div>
{/if}
```

- [ ] **Step 3: Playwright smoke (structural)**

```typescript
// frontend/tests/skills-file-editor.spec.ts
import { test, expect } from '@playwright/test';
import { mockRpc } from './helpers';

test('selecting a bundle file opens the editor', async ({ page }) => {
	await mockRpc(page, {
		getSkill: { id: 's1', name: 'edit-skill', description: 'd', hasExecutableBundle: true, fileManifest: [{ path: 'scripts/go.py', size: 8, executable: true }], /* ...other required fields... */ }
	});
	// stub the file read endpoint
	await page.route('**/rpc/skills/s1/file*', (route) => route.fulfill({ json: { success: true, data: { path: 'scripts/go.py', content: 'print(1)' } } }));
	await page.goto('/library/skills/s1');
	await page.getByTestId('skill-file-open').first().click();
	await expect(page.getByTestId('skill-file-editor')).toBeVisible();
	await expect(page.getByTestId('skill-file-save')).toBeVisible();
});
```

> Fill in the full `getSkill` mock fields to satisfy `SkillDetail`; copy the shape from the existing `skills.spec.ts` detail test.

- [ ] **Step 4: Checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-file-editor.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/routes/library/skills frontend/src/lib/ash/api.ts frontend/tests/skills-file-editor.spec.ts
git commit -m "feat(skills): in-browser bundle file-tree editor (monospace textarea)"
```

---

## Task 5: Publish toggle + Public badge on skill detail (SPA)

**Files:**
- Modify: `frontend/src/routes/library/skills/[skillId]/+page.svelte`
- Modify: `frontend/src/lib/ash/api.ts` (publish/unpublish wrappers)
- Modify: `frontend/src/lib/ash/api.ts` SkillDetail type (add `isPublic`)
- Test: `frontend/tests/skills-publish.spec.ts`

**Interfaces:**
- Consumes: `publish_skill`/`unpublish_skill` RPC (Task 1).
- Produces: a publish toggle in the detail dropdown + a Public badge.

- [ ] **Step 1: Add wrappers + type field**

```typescript
// api.ts: extend SkillSummary/SkillDetail
// add `isPublic: boolean;` to SkillSummary and `'isPublic'` to SKILL_SUMMARY_FIELDS

export function publishSkill(id: string): Promise<RpcResult<SkillDetail>> {
	return run((opts) => rpc.publishSkill({ identity: id, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export function unpublishSkill(id: string): Promise<RpcResult<SkillDetail>> {
	return run((opts) => rpc.unpublishSkill({ identity: id, fields: SKILL_DETAIL_FIELDS, ...opts }));
}
```

- [ ] **Step 2: Wire the toggle + badge (mirror Prompt detail)**

In the detail component's dropdown menu, add an item toggling publish (like the prompt detail's `togglePublish`), and render a "Public" badge in the meta chips when `skill.isPublic`.

```typescript
async function togglePublish() {
	const r = skill.isPublic ? await unpublishSkill(skill.id) : await publishSkill(skill.id);
	if (r.success) skill = r.data;
}
```

```svelte
{#if skill.isPublic}
	<span class="rounded-full border border-input bg-secondary px-2 py-0.5 text-[10px] font-medium text-secondary-foreground" data-testid="skill-public-badge">Public</span>
{/if}
```

- [ ] **Step 3: Regenerate types + Playwright smoke**

Run: `set -a && source .env && set +a && mix ash_typescript.codegen`

```typescript
// frontend/tests/skills-publish.spec.ts
import { test, expect } from '@playwright/test';
import { mockRpc } from './helpers';

test('published skill shows the Public badge', async ({ page }) => {
	await mockRpc(page, { getSkill: { id: 's1', name: 'p', description: 'd', isPublic: true, hasExecutableBundle: false, fileManifest: [], /* ... */ } });
	await page.goto('/library/skills/s1');
	await expect(page.getByTestId('skill-public-badge')).toBeVisible();
});
```

- [ ] **Step 4: Checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-publish.spec.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/routes/library/skills frontend/src/lib/ash/api.ts frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts frontend/tests/skills-publish.spec.ts
git commit -m "feat(skills): publish toggle + Public badge on skill detail"
```

---

## Task 6: Public marketplace gallery (SPA)

**Files:**
- Create: `frontend/src/routes/library/skills/explore/+page.svelte`
- Modify: `frontend/src/lib/ash/api.ts` (public search + copy wrappers)
- Modify: the Library nav/mode to surface an "Explore" entry for skills
- Test: `frontend/tests/skills-explore.spec.ts`

**Interfaces:**
- Consumes: `public_search_skills` RPC (Task 1), `POST /rpc/skills/copy` (Task 2).
- Produces: a browse-and-copy gallery.

- [ ] **Step 1: Add wrappers**

```typescript
// api.ts
export function publicSearchSkills(query: string): Promise<RpcResult<SkillSummary[]>> {
	return run((opts) => rpc.publicSearchSkills({ input: { query, sortBy: 'recent' }, fields: SKILL_SUMMARY_FIELDS, ...opts }));
}

export async function copySkillToLibrary(sourceSkillId: string): Promise<RpcResult<{ id: string; name: string }>> {
	return rawPost('/rpc/skills/copy', { source_skill_id: sourceSkillId });
}
```

- [ ] **Step 2: Build the gallery**

Mirror the existing skills gallery card grid (`frontend/src/routes/library/skills/components/skill-card.svelte`), driven by `publicSearchSkills`, each card with a "Copy to my library" button calling `copySkillToLibrary` then navigating to the created skill.

```svelte
<!-- frontend/src/routes/library/skills/explore/+page.svelte -->
<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { publicSearchSkills, copySkillToLibrary, type SkillSummary } from '$lib/ash/api';

	let skills = $state<SkillSummary[]>([]);
	let query = $state('');
	let copying = $state<string | null>(null);

	onMount(search);

	async function search() {
		const r = await publicSearchSkills(query);
		if (r.success) skills = r.data;
	}

	async function copy(id: string) {
		copying = id;
		const r = await copySkillToLibrary(id);
		copying = null;
		if (r.success) void goto(`${base}/library/skills/${r.data.id}`);
	}
</script>

<div data-testid="skills-explore" class="space-y-4">
	<input class="wb-input w-full" placeholder="Search public skills…" bind:value={query} oninput={() => void search()} data-testid="explore-search" />
	<div class="grid grid-cols-2 gap-3" data-testid="explore-grid">
		{#each skills as skill (skill.id)}
			<div class="rounded-xl border border-input p-3">
				<p class="text-sm font-medium">{skill.displayName ?? skill.name}</p>
				<p class="line-clamp-2 text-xs text-muted-foreground">{skill.description}</p>
				<button class="wb-pill-btn mt-2 text-xs" data-testid="explore-copy" disabled={copying === skill.id} onclick={() => void copy(skill.id)}>
					{copying === skill.id ? 'Copying…' : 'Copy to my library'}
				</button>
			</div>
		{/each}
	</div>
</div>
```

- [ ] **Step 3: Surface an Explore entry**

Add a link to `/library/skills/explore` from the Library skills view header (follow how the Library mode renders its section actions; a simple `<.link navigate>`-equivalent button in the SPA). Keep it minimal: one entry point.

- [ ] **Step 4: Regenerate types + Playwright smoke**

Run: `set -a && source .env && set +a && mix ash_typescript.codegen`

```typescript
// frontend/tests/skills-explore.spec.ts
import { test, expect } from '@playwright/test';
import { mockRpc } from './helpers';

test('explore lists public skills and offers copy', async ({ page }) => {
	await mockRpc(page, { publicSearchSkills: [{ id: 'p1', name: 'shared', displayName: null, description: 'd', requestedTools: [], version: null, license: null, sourceFormat: 'skill_md', hasExecutableBundle: false, isSharedToWorkspace: false, workspaceId: null, isFavorited: false, isPublic: true, body: 'b' }] });
	await page.goto('/library/skills/explore');
	await expect(page.getByTestId('explore-grid')).toContainText('shared');
	await expect(page.getByTestId('explore-copy')).toBeVisible();
});
```

- [ ] **Step 5: Checks**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-explore.spec.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/routes/library/skills/explore frontend/src/lib/ash/api.ts frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts frontend/tests/skills-explore.spec.ts
git commit -m "feat(skills): public marketplace gallery with copy-to-library"
```

---

## Task 7: Full-suite gate

- [ ] **Step 1: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Backend**

Run: `mix test test/magus/skills test/magus_web/rpc`
Expected: PASS (scope assertions to seeded rows per the shared-DB caveat).

- [ ] **Step 3: Frontend**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json && npx playwright test tests/skills-file-editor.spec.ts tests/skills-publish.spec.ts tests/skills-explore.spec.ts`
Expected: PASS.

- [ ] **Step 4: Commit any pending regen**

```bash
git add frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "chore(skills): regenerate RPC types for phase 3"
```

---

## Notes for the executor

- **Editor deviation** (top of this doc): monospace `<textarea>`, not CodeMirror. Do not add a code-editor dependency for this phase.
- **Re-gating is the point**: editing a file changes `bundle_sha`, so open conversations that had approved the old bundle will re-prompt. Confirm the `update_file` path recomputes the sha and do not add a "keep approval" shortcut.
- **Copy is a snapshot**: `copy_skill_to_library` clones via Export to Import, so a later change to the source does not affect copies. Copies arrive private, un-approved, un-trusted.
- **Admin unpublish**: `unpublish_as_admin` is gated on `Magus.Checks.IsAdmin`; there is no admin UI in this plan (invoke via the existing admin surface or console). Building an admin moderation page is a follow-up.
- **Depends on Plans 2A + 2B being merged** (uses `bundle_sha`, `Export`, `Unpack`, approval re-gating).
