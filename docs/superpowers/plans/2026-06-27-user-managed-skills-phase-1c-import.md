# User-Managed Skills — Phase 1C-import: Bundle Import Pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import a skill bundle (a zip of `SKILL.md` plus optional `scripts/`, `references/`, `assets/`) into a `Magus.Skills.Skill` record: safely unpack the zip, parse the `SKILL.md` frontmatter fully, store the archive without indexing, compute a file manifest, and create the Skill. Exposed to the SPA via a multipart `/rpc/skills/import` endpoint.

**Architecture:** Three small new modules under `Magus.Skills.Import` (Unpack, Parser, and the `import_bundle/2` orchestration), a new `:import` create action on the existing `Skill` resource, and an RPC controller mirroring the existing `UploadController`. The archive bytes are stored directly through `Magus.Files.Storage` (bypassing the `Files.File` `:process_file` indexing trigger). No sandbox, no approval, no agent involvement: this plan ends at "a Skill row exists with a stored bundle and a manifest."

**Tech Stack:** Elixir, Ash 3.x, Erlang `:zip` (stdlib), `yaml_front_matter` (hex, already a dep), Phoenix controller, ExUnit.

## Plan sequence (context)

This is the **import half of Phase 1C**, built on 1A (the `Skill` resource with bundle columns already present) and independent of 1B. It produces working, testable software: import an Anthropic-format skill and get a Skill record with a stored bundle. The **runtime half of 1C** (sandbox materialization, the cross-turn first-run approval gate, secret sourcing, and the `create_skill` agent tool) is a separate plan, because the approval gate is asynchronous (return-pending-and-resume) and needs its own design. Nothing in this plan touches the sandbox, conversations, or approval.

## Decisions baked in

- **Bundle storage is non-indexing.** The archive bytes are written via `Magus.Files.Storage.store/3` to `skills/<user_id>/<sha256>.zip` and never go through `Files.File.create` (which runs `run_oban_trigger(:process_file)`). Content-addressed (sha256 of the zip) so the storage path is known before the Skill row is created.
- **`SKILL.md` parsed in full.** `YamlFrontMatter.parse/1` yields the complete frontmatter map; we keep all standard keys (`name`, `description`, `license`, `compatibility`, `allowed-tools`, `metadata`), unlike the Registry parser which keeps only a subset. `allowed-tools` is a space-separated string in the file and maps to the `requested_tools` list. Magus extensions ride in `metadata["x-magus"]` as a JSON string (`required_secrets`, `runtime_hints`, `version`).
- **`has_executable_bundle`** is true when the bundle contains any file under `scripts/`.
- **`source_format`** for an imported `SKILL.md` is `:skill_md`.

## Global Constraints

- Call resources through domain code interfaces (`Magus.Skills.import_skill/2`), never `Ash.read/4`. Always pass `actor:`.
- Storage: `Magus.Files.Storage.store(path, bytes, opts) :: {:ok, path} | {:error, _}` and `Magus.Files.Storage.get(path) :: {:ok, bytes} | {:error, _}`. Stamp the backend with `Magus.Files.Storage.backend_name/0`.
- Safe unpack MUST reject path traversal using the same boundary check as `Magus.Files.Storage.Local.full_path/1` (resolve with `Path.expand`, require the result to equal the base or start with `base <> "/"`), and enforce limits (max file count, max total bytes, max single-file bytes). Reject absolute entry paths and `..` segments.
- No schema/migration changes (the bundle columns already exist on `Skill` from 1A).
- Tests: resource/import tests use `use Magus.ResourceCase, async: true`; pure unit tests use `use ExUnit.Case, async: true`. Worktree test command: `set -a && source .env && set +a && MIX_ENV=test mix test <path>`. Before committing: `set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors`.
- No em dashes in prose or comments.

---

### Task 1: `Magus.Skills.Import.Unpack` — safe in-process zip unpack

**Files:**
- Create: `lib/magus/skills/import/unpack.ex`
- Test: `test/magus/skills/import/unpack_test.exs`

**Interfaces:**
- Produces: `Magus.Skills.Import.Unpack.unpack(zip_bytes :: binary) :: {:ok, %{skill_md: binary, files: [{String.t(), binary}]}} | {:error, atom}`. `files` excludes `SKILL.md` and uses forward-slash relative paths. Errors: `:invalid_zip`, `:missing_skill_md`, `:unsafe_path`, `:too_many_files`, `:bundle_too_large`, `:file_too_large`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/import/unpack_test.exs`:

```elixir
defmodule Magus.Skills.Import.UnpackTest do
  use ExUnit.Case, async: true

  alias Magus.Skills.Import.Unpack

  # Build an in-memory zip from a list of {path_charlist, content_binary}.
  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_name, bytes}} = :zip.create(~c"bundle.zip", files, [:memory])
    bytes
  end

  test "unpacks SKILL.md and bundle files" do
    bytes = zip([{"SKILL.md", "---\nname: x\n---\nbody"}, {"scripts/run.py", "print(1)"}])
    assert {:ok, %{skill_md: md, files: files}} = Unpack.unpack(bytes)
    assert md =~ "name: x"
    assert {"scripts/run.py", "print(1)"} in files
    refute Enum.any?(files, fn {p, _} -> p == "SKILL.md" end)
  end

  test "rejects a missing SKILL.md" do
    bytes = zip([{"scripts/run.py", "print(1)"}])
    assert {:error, :missing_skill_md} = Unpack.unpack(bytes)
  end

  test "rejects path traversal entries" do
    bytes = zip([{"SKILL.md", "x"}, {"../evil.sh", "rm -rf"}])
    assert {:error, :unsafe_path} = Unpack.unpack(bytes)
  end

  test "rejects invalid zip bytes" do
    assert {:error, :invalid_zip} = Unpack.unpack("not a zip")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import/unpack_test.exs`
Expected: FAIL (`Magus.Skills.Import.Unpack` undefined).

- [ ] **Step 3: Implement the module**

Create `lib/magus/skills/import/unpack.ex`:

```elixir
defmodule Magus.Skills.Import.Unpack do
  @moduledoc """
  Safe in-process unpack of a skill bundle zip. Rejects path traversal and
  enforces size/count limits. Returns the SKILL.md body and the remaining
  bundle files keyed by forward-slash relative path.
  """

  @max_files 500
  @max_total_bytes 25 * 1024 * 1024
  @max_file_bytes 10 * 1024 * 1024

  @spec unpack(binary) ::
          {:ok, %{skill_md: binary, files: [{String.t(), binary}]}}
          | {:error, atom}
  def unpack(zip_bytes) when is_binary(zip_bytes) do
    case :zip.unzip(zip_bytes, [:memory]) do
      {:ok, entries} -> from_entries(entries)
      {:error, _} -> {:error, :invalid_zip}
    end
  end

  defp from_entries(entries) do
    normalized =
      Enum.map(entries, fn {name, content} -> {strip_top_dir(to_string(name)), content} end)

    cond do
      length(normalized) > @max_files ->
        {:error, :too_many_files}

      total_bytes(normalized) > @max_total_bytes ->
        {:error, :bundle_too_large}

      Enum.any?(normalized, fn {_p, c} -> byte_size(c) > @max_file_bytes end) ->
        {:error, :file_too_large}

      Enum.any?(normalized, fn {p, _c} -> unsafe?(p) end) ->
        {:error, :unsafe_path}

      true ->
        case Enum.split_with(normalized, fn {p, _} -> p == "SKILL.md" end) do
          {[{"SKILL.md", md} | _], rest} -> {:ok, %{skill_md: md, files: rest}}
          {[], _} -> {:error, :missing_skill_md}
        end
    end
  end

  # An archive may wrap everything in a single top-level dir (e.g. "my-skill/").
  # Only strip it when EVERY entry shares that prefix; otherwise keep paths as-is.
  defp strip_top_dir(path), do: path

  defp total_bytes(entries), do: Enum.reduce(entries, 0, fn {_p, c}, acc -> acc + byte_size(c) end)

  # Reject absolute paths, "." / ".." segments, and anything that would resolve
  # outside a notional base, mirroring Magus.Files.Storage.Local.full_path/1.
  defp unsafe?(path) do
    base = Path.expand("/__skill_base__")
    full = Path.expand(Path.join(base, path))

    String.starts_with?(path, "/") or
      Enum.any?(Path.split(path), &(&1 in [".", ".."])) or
      not (full == base or String.starts_with?(full, base <> "/"))
  end
end
```

(Note: `strip_top_dir/1` is intentionally identity in v1: bundles authored as a flat tree with `SKILL.md` at the root are the common case and what the import test produces. A later refinement can collapse a single shared top-level directory. Document this in the report if you keep it identity.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import/unpack_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/import/unpack.ex test/magus/skills/import/unpack_test.exs
git commit -m "feat(skills): safe in-process zip unpack for bundle import"
```

---

### Task 2: `Magus.Skills.Import.Parser` — parse and normalize SKILL.md

**Files:**
- Create: `lib/magus/skills/import/parser.ex`
- Test: `test/magus/skills/import/parser_test.exs`

**Interfaces:**
- Produces: `Magus.Skills.Import.Parser.parse(skill_md :: binary) :: {:ok, map} | {:error, atom}`. The map carries the normalized Skill attributes: `%{name, description, body, license, compatibility, requested_tools, required_secrets, runtime_hints, metadata, version, source_format: :skill_md}`. Errors: `:invalid_frontmatter`, `:missing_name`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/import/parser_test.exs`:

```elixir
defmodule Magus.Skills.Import.ParserTest do
  use ExUnit.Case, async: true

  alias Magus.Skills.Import.Parser

  test "parses standard frontmatter and maps allowed-tools" do
    md = """
    ---
    name: pdf-filler
    description: Fill PDF forms
    license: MIT
    allowed-tools: web_search run_code
    ---
    # PDF
    Do the thing.
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.name == "pdf-filler"
    assert m.description == "Fill PDF forms"
    assert m.license == "MIT"
    assert m.requested_tools == ["web_search", "run_code"]
    assert m.body =~ "Do the thing."
    assert m.source_format == :skill_md
  end

  test "extracts Magus extensions from metadata x-magus" do
    md = """
    ---
    name: with-secrets
    description: d
    metadata:
      x-magus: "{\\"version\\":\\"2.0\\",\\"required_secrets\\":[{\\"key\\":\\"OPENAI_API_KEY\\",\\"description\\":\\"key\\"}]}"
    ---
    body
    """

    assert {:ok, m} = Parser.parse(md)
    assert m.version == "2.0"
    assert [%{"key" => "OPENAI_API_KEY"}] = m.required_secrets
  end

  test "rejects frontmatter without a name" do
    assert {:error, :missing_name} = Parser.parse("---\ndescription: d\n---\nbody")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import/parser_test.exs`
Expected: FAIL (`Magus.Skills.Import.Parser` undefined).

- [ ] **Step 3: Implement the module**

Create `lib/magus/skills/import/parser.ex`:

```elixir
defmodule Magus.Skills.Import.Parser do
  @moduledoc """
  Parse a SKILL.md into normalized Skill attributes. Keeps all standard
  Agent Skills frontmatter (name, description, license, compatibility,
  allowed-tools, metadata) and lifts Magus extensions out of the
  metadata["x-magus"] JSON string.
  """

  @spec parse(binary) :: {:ok, map} | {:error, atom}
  def parse(skill_md) when is_binary(skill_md) do
    case YamlFrontMatter.parse(skill_md) do
      {:ok, fm, body} when is_map(fm) -> normalize(fm, body)
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp normalize(fm, body) do
    case fm["name"] do
      name when is_binary(name) and name != "" ->
        ext = magus_extensions(fm)

        {:ok,
         %{
           name: name,
           description: fm["description"] || "",
           body: String.trim(body),
           license: fm["license"],
           compatibility: fm["compatibility"],
           requested_tools: split_allowed_tools(fm["allowed-tools"]),
           required_secrets: Map.get(ext, "required_secrets", []),
           runtime_hints: Map.get(ext, "runtime_hints", %{}),
           version: Map.get(ext, "version"),
           metadata: Map.drop(fm["metadata"] || %{}, ["x-magus"]),
           source_format: :skill_md
         }}

      _ ->
        {:error, :missing_name}
    end
  end

  # allowed-tools is a space-separated string in the spec (not a list); accept a
  # list too in case a producer emitted one.
  defp split_allowed_tools(nil), do: []
  defp split_allowed_tools(s) when is_binary(s), do: String.split(s, ~r/\s+/, trim: true)
  defp split_allowed_tools(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp magus_extensions(fm) do
    with %{} = meta <- fm["metadata"],
         raw when is_binary(raw) <- meta["x-magus"],
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      decoded
    else
      _ -> %{}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import/parser_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/import/parser.ex test/magus/skills/import/parser_test.exs
git commit -m "feat(skills): SKILL.md parser preserving full frontmatter + x-magus"
```

---

### Task 3: `Skill` `:import` create action

**Files:**
- Modify: `lib/magus/skills/skill.ex` (add the `:import` create action)
- Modify: `lib/magus/skills/skills.ex` (add `define :import_skill, action: :import`)
- Test: `test/magus/skills/skill_import_action_test.exs`

**Interfaces:**
- Produces: `Magus.Skills.import_skill(attrs, opts)` creating a Skill that accepts the bundle fields (`bundle_path`, `bundle_backend`, `bundle_byte_size`, `file_manifest`, `has_executable_bundle`) in addition to the authoring fields.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/skill_import_action_test.exs`:

```elixir
defmodule Magus.Skills.SkillImportActionTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills

  test "import_skill accepts bundle fields and sets the owner" do
    owner = generate(user())

    {:ok, skill} =
      Skills.import_skill(
        %{
          name: "imported",
          description: "d",
          body: "# I",
          requested_tools: ["web_search"],
          bundle_path: "skills/#{owner.id}/abc.zip",
          bundle_backend: "local",
          bundle_byte_size: 123,
          file_manifest: [%{"path" => "scripts/run.py", "size" => 8}],
          has_executable_bundle: true,
          source_format: :skill_md
        },
        actor: owner
      )

    assert skill.has_executable_bundle == true
    assert skill.bundle_path == "skills/#{owner.id}/abc.zip"
    assert skill.user_id == owner.id
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/skill_import_action_test.exs`
Expected: FAIL (`import_skill` undefined / `:import` action missing).

- [ ] **Step 3: Add the `:import` create action**

In `lib/magus/skills/skill.ex`, inside `actions do ... end`, add (after the existing `:create`):

```elixir
    create :import do
      description "Create a skill from an imported bundle (accepts bundle fields)."

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
        :workspace_id,
        :bundle_path,
        :bundle_backend,
        :bundle_byte_size,
        :file_manifest,
        :has_executable_bundle
      ]

      change relate_actor(:user)
    end
```

In `lib/magus/skills/skills.ex`, add to the `resource Magus.Skills.Skill do` interfaces:

```elixir
      define :import_skill, action: :import
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/skill_import_action_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/skill.ex lib/magus/skills/skills.ex test/magus/skills/skill_import_action_test.exs
git commit -m "feat(skills): :import create action accepting bundle fields"
```

---

### Task 4: `Magus.Skills.Import.import_bundle/2` orchestration

**Files:**
- Create: `lib/magus/skills/import.ex`
- Test: `test/magus/skills/import_test.exs`

**Interfaces:**
- Consumes: `Unpack.unpack/1`, `Parser.parse/1`, `Magus.Files.Storage.store/3` + `backend_name/0`, `Magus.Skills.import_skill/2`.
- Produces: `Magus.Skills.Import.import_bundle(zip_bytes :: binary, opts) :: {:ok, %Skill{}} | {:error, term}` where `opts` carries `:actor` (required) and `:workspace_id` (optional). Stores the archive at `skills/<user_id>/<sha256>.zip` and builds a `file_manifest` of `%{"path", "size", "sha256", "executable"}`.

- [ ] **Step 1: Write the failing test**

Create `test/magus/skills/import_test.exs`:

```elixir
defmodule Magus.Skills.ImportTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills.Import

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "imports a bundle into a Skill with a stored archive and manifest" do
    owner = generate(user())

    bytes =
      zip([
        {"SKILL.md", "---\nname: importer\ndescription: D\nallowed-tools: web_search\n---\n# I\nRun scripts/go.py"},
        {"scripts/go.py", "print('hi')"}
      ])

    assert {:ok, skill} = Import.import_bundle(bytes, actor: owner)
    assert skill.name == "importer"
    assert skill.requested_tools == ["web_search"]
    assert skill.has_executable_bundle == true
    assert skill.bundle_byte_size == byte_size(bytes)
    assert [%{"path" => "scripts/go.py"} | _] = skill.file_manifest

    # The archive round-trips through storage.
    assert {:ok, ^bytes} = Magus.Files.Storage.get(skill.bundle_path)
  end

  test "propagates a parse error" do
    owner = generate(user())
    bytes = zip([{"SKILL.md", "---\ndescription: no name\n---\nbody"}])
    assert {:error, :missing_name} = Import.import_bundle(bytes, actor: owner)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import_test.exs`
Expected: FAIL (`Magus.Skills.Import` undefined).

- [ ] **Step 3: Implement the orchestration**

Create `lib/magus/skills/import.ex`:

```elixir
defmodule Magus.Skills.Import do
  @moduledoc """
  Orchestrates importing a skill bundle zip into a `Magus.Skills.Skill`:
  unpack -> parse SKILL.md -> store the archive (non-indexing) -> compute the
  file manifest -> create the Skill via the :import action.
  """

  alias Magus.Skills.Import.{Unpack, Parser}

  @spec import_bundle(binary, keyword) :: {:ok, struct} | {:error, term}
  def import_bundle(zip_bytes, opts) when is_binary(zip_bytes) do
    actor = Keyword.fetch!(opts, :actor)
    workspace_id = Keyword.get(opts, :workspace_id)

    with {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(zip_bytes),
         {:ok, manifest_attrs} <- Parser.parse(md),
         sha <- sha256_hex(zip_bytes),
         bundle_path <- "skills/#{actor.id}/#{sha}.zip",
         {:ok, _} <- Magus.Files.Storage.store(bundle_path, zip_bytes) do
      attrs =
        Map.merge(manifest_attrs, %{
          bundle_path: bundle_path,
          bundle_backend: Magus.Files.Storage.backend_name(),
          bundle_byte_size: byte_size(zip_bytes),
          file_manifest: build_manifest(files),
          has_executable_bundle: Enum.any?(files, fn {p, _} -> String.starts_with?(p, "scripts/") end),
          workspace_id: workspace_id
        })

      Magus.Skills.import_skill(attrs, actor: actor)
    end
  end

  defp build_manifest(files) do
    Enum.map(files, fn {path, content} ->
      %{
        "path" => path,
        "size" => byte_size(content),
        "sha256" => sha256_hex(content),
        "executable" => String.starts_with?(path, "scripts/")
      }
    end)
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/import_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/import.ex test/magus/skills/import_test.exs
git commit -m "feat(skills): import_bundle orchestration (unpack, parse, store, create)"
```

---

### Task 5: `/rpc/skills/import` multipart controller

**Files:**
- Create: `lib/magus_web/rpc/skills_controller.ex`
- Modify: `lib/magus_web/core_router.ex` (add the route in the `scope "/rpc"` block)
- Test: `test/magus_web/rpc/skills_controller_test.exs`

**Interfaces:**
- Produces: `POST /rpc/skills/import` (session-authenticated, `:rpc` pipeline) accepting a multipart `file` (the zip) plus optional `workspace_id`, returning the AshTypescript RPC envelope `%{success: true, data: %{id, name}}` or `%{success: false, errors: [...]}`. Mirrors `MagusWeb.Rpc.UploadController`.

- [ ] **Step 1: Write the failing test**

Create `test/magus_web/rpc/skills_controller_test.exs`:

```elixir
defmodule MagusWeb.Rpc.SkillsControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "imports a bundle and returns the RPC envelope", %{conn: conn} do
    user = generate(user())
    bytes = zip([{"SKILL.md", "---\nname: ctrl-import\ndescription: D\n---\nbody"}])

    upload = %Plug.Upload{path: write_tmp(bytes), filename: "b.zip", content_type: "application/zip"}

    conn =
      conn
      |> log_in_user(user)
      |> post(~p"/rpc/skills/import", %{"file" => upload})

    assert %{"success" => true, "data" => %{"name" => "ctrl-import"}} = json_response(conn, 200)
  end

  defp write_tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "skill-#{System.unique_integer([:positive])}.zip")
    File.write!(path, bytes)
    path
  end
end
```

(Note: confirm the test helpers `log_in_user/2` and the `~p` route sigil exist in this project's `MagusWeb.ConnCase`. If `log_in_user` differs, use the project's session-login helper for controller tests; the assertion on the envelope is the point. If `MagusWeb.ConnCase` is not the convention, use whatever the existing controller tests under `test/magus_web/` use.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus_web/rpc/skills_controller_test.exs`
Expected: FAIL (route/controller undefined).

- [ ] **Step 3: Create the controller**

Create `lib/magus_web/rpc/skills_controller.ex` (mirrors `UploadController`'s structure and envelope):

```elixir
defmodule MagusWeb.Rpc.SkillsController do
  @moduledoc """
  Multipart skill-bundle import endpoint for the SPA (`POST /rpc/skills/import`).
  Runs in the `:rpc` pipeline (session-authenticated actor) and delegates to
  `Magus.Skills.Import.import_bundle/2`. Responses mirror the AshTypescript RPC
  envelope so the SPA data layer shares error handling.
  """
  use MagusWeb, :controller

  require Logger

  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    with {:ok, bytes} <- File.read(upload.path),
         {:ok, skill} <-
           Magus.Skills.Import.import_bundle(bytes,
             actor: user,
             workspace_id: cast_uuid(params["workspace_id"])
           ) do
      json(conn, %{success: true, data: %{id: skill.id, name: skill.name}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(error_envelope("missing multipart \"file\" field"))
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  defp error_envelope(reason) do
    message =
      case reason do
        r when is_binary(r) -> r
        r when is_atom(r) -> "Import failed: #{r}"
        %Ash.Error.Invalid{errors: [first | _]} when is_exception(first) -> Exception.message(first)
        other ->
          Logger.warning("RPC skill import failed: #{inspect(other)}")
          "Import failed"
      end

    %{
      success: false,
      errors: [%{type: "import_failed", message: message, shortMessage: "Import failed", vars: %{}, fields: [], path: []}]
    }
  end
end
```

- [ ] **Step 4: Add the route**

In `lib/magus_web/core_router.ex`, inside `scope "/rpc", MagusWeb.Rpc do ... pipe_through :rpc ... end`, add next to the existing `post "/upload", UploadController, :create`:

```elixir
    post "/skills/import", SkillsController, :create
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus_web/rpc/skills_controller_test.exs`
Expected: PASS. If the conn-test helpers differ, adjust per the Step 1 note; the controller and route are the deliverable.

- [ ] **Step 6: Full import suite + warnings check, then commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus/skills/ test/magus_web/rpc/skills_controller_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
```
Expected: green, no warnings. Then:
```bash
git add lib/magus_web/rpc/skills_controller.ex lib/magus_web/core_router.ex test/magus_web/rpc/skills_controller_test.exs
git commit -m "feat(skills): /rpc/skills/import multipart bundle import endpoint"
```

---

## Self-Review

- **Spec/scope coverage:** safe unpack (Task 1), full SKILL.md parse + normalize with allowed-tools and x-magus (Task 2), a bundle-accepting create action (Task 3), the end-to-end `import_bundle` storing the archive non-indexed with a manifest (Task 4), and the multipart import endpoint (Task 5) cover the import half of 1C. Materialization, the cross-turn approval gate, secret sourcing, and `create_skill` are the separate runtime-half plan and are explicitly excluded.
- **Placeholders:** none. The two "confirm the test helper" notes (the conn-test login helper, the `strip_top_dir` identity choice) name the exact thing to verify and a working default; they are not unfinished logic.
- **Type/interface consistency:** `Unpack.unpack/1`'s `%{skill_md, files}` is consumed by `import_bundle/2`; `Parser.parse/1`'s normalized map keys match the `:import` action's accepted attributes; `file_manifest` entries use string keys (`"path"`, `"size"`, `"sha256"`, `"executable"`) consistently in Tasks 3, 4; `import_skill/2` (Task 3) is called by `import_bundle/2` (Task 4); the controller (Task 5) calls `import_bundle/2`.
- **No migration / no indexing:** the bundle columns already exist on `Skill` (1A); the archive is stored via `Storage.store` directly, never `Files.File.create`.
