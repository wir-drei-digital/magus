# User Skills Phase 2B (Exchange) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make skills round-trip: generate a spec-valid `SKILL.md` bundle from the current (possibly edited) structured fields, import from a URL or an AGENTS.md file, preinstall declared packages at materialization, and fix the import hardening gaps.

**Architecture:** Add `Magus.Skills.Export` as the inverse of the existing `Import.Parser` and make the download controller serve it. Add `Magus.Skills.Import.URLFetcher` (SSRF-guarded HTTPS fetch, forge-URL rewrite, no git client) and `Magus.Skills.Import.AgentsMd` (prompt-only). Extend the RPC import controller with `url` and `agents` params. Wire `runtime_hints` package preinstall into the Materializer. Fix the unpack directory-entry bug, orphaned-blob cleanup, and the missing limit tests.

**Tech Stack:** Elixir, Ash 3.x, Req (HTTP), `:zip` (bundle pack/unpack), YamlFrontMatter (parse), the existing `Magus.Sandbox.Orchestrator` for preinstall.

## Global Constraints

- **No em dashes** in written content. Use colons/periods/commas.
- **Never run `mix ash.reset`**. Use `mix ash.codegen <name>` then `mix ash.migrate` (this plan adds no columns, so likely no migration).
- **SSRF**: reuse `Magus.Agents.Tools.Integrations.SsrfValidator.validate_url/1` for every outbound fetch. Reject private/link-local/loopback, non-http(s) schemes, and cap redirects + body size.
- **Package preinstall**: allowlisted managers only (`pip`/`uv`, `npm`); package names validated against a strict charset and passed as argv tokens, never interpolated into a shell string.
- **Export must stay spec-valid**: `allowed-tools` is a space-separated string; Magus extras go under `metadata["x-magus"]` as a single JSON string. A Magus skill must remain a valid Anthropic Agent Skill.
- **Frontend tests stay structural** (`data-testid` + counts).
- **CI compiles with `--warnings-as-errors`**: run `MIX_ENV=test mix compile --warnings-as-errors` before finishing a task.
- **Depends on Plan 2A** for `Skill.bundle_sha` (Export recomputes and the download controller serves a fresh bundle; the sha is set on import in 2A Task 2). If 2A is not merged, add `bundle_sha` first.

## Shared Interfaces (defined here, referenced by Plan 3)

```elixir
# Task 2
Magus.Skills.Export.generate_bundle(skill :: map()) :: {:ok, binary()} | {:error, term()}
  # returns zip bytes: SKILL.md (from structured fields) + artifact files from the stored bundle

# Task 3
Magus.Skills.Import.URLFetcher.fetch(url :: String.t()) :: {:ok, binary()} | {:error, term()}
  # returns zip bytes; rewrites github/gitlab repo URLs to archive URLs; SSRF-guarded

# Task 4
Magus.Skills.Import.AgentsMd.parse(markdown :: binary(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  # returns Skill import attrs for a prompt-only skill (source_format: :agents_md)
```

---

## File Structure

New backend:
- `lib/magus/skills/export.ex` — compose a SKILL.md bundle from structured fields
- `lib/magus/skills/import/url_fetcher.ex` — SSRF-guarded HTTPS zip fetch + forge rewrite
- `lib/magus/skills/import/agents_md.ex` — AGENTS.md to prompt-only skill attrs

Modified backend:
- `lib/magus/skills/import/unpack.ex` — skip directory entries; add limit tests
- `lib/magus/skills/import.ex` — orphaned-blob cleanup on failure after store
- `lib/magus/skills/materializer.ex` — `runtime_hints` package preinstall
- `lib/magus_web/workbench/controllers/skill_controller.ex` — download serves the generated export
- `lib/magus_web/rpc/skills_controller.ex` — accept `url` and `agents` params
- `lib/magus/skills/discovery.ex` — per-turn discovery cache (carry-over)
- `lib/magus/skills/loader.ex` (from 2A) — sentinel-marker idempotency + nil-actor log (carry-over)

---

## Task 1: Fix unpack directory entries + add limit tests

**Files:**
- Modify: `lib/magus/skills/import/unpack.ex`
- Test: `test/magus/skills/import/unpack_test.exs`

**Interfaces:**
- Produces: `Unpack.unpack/1` no longer returns zero-byte directory entries in `files`.

- [ ] **Step 1: Write the failing tests**

```elixir
# test/magus/skills/import/unpack_test.exs
defmodule Magus.Skills.Import.UnpackTest do
  use ExUnit.Case, async: true
  alias Magus.Skills.Import.Unpack

  test "skips zip directory entries" do
    {:ok, {_n, bytes}} =
      :zip.create(
        ~c"b.zip",
        [
          {~c"SKILL.md", "---\nname: d\ndescription: x\n---\nbody"},
          {~c"scripts/", ""},
          {~c"scripts/go.py", "print(1)"}
        ],
        [:memory]
      )

    {:ok, %{files: files}} = Unpack.unpack(bytes)
    paths = Enum.map(files, fn {p, _} -> p end)

    refute "scripts/" in paths
    assert "scripts/go.py" in paths
  end

  test "rejects too many files" do
    entries =
      [{~c"SKILL.md", "---\nname: d\ndescription: x\n---\nb"}] ++
        Enum.map(1..600, fn i -> {String.to_charlist("f#{i}.txt"), "x"} end)

    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", entries, [:memory])
    assert {:error, :too_many_files} = Unpack.unpack(bytes)
  end

  test "rejects a single oversized file" do
    big = :binary.copy("x", 11 * 1024 * 1024)
    {:ok, {_n, bytes}} =
      :zip.create(~c"b.zip", [{~c"SKILL.md", "---\nname: d\ndescription: x\n---\nb"}, {~c"big.bin", big}], [:memory])

    assert {:error, :file_too_large} = Unpack.unpack(bytes)
  end

  test "rejects path traversal" do
    {:ok, {_n, bytes}} =
      :zip.create(~c"b.zip", [{~c"SKILL.md", "---\nname: d\ndescription: x\n---\nb"}, {~c"../evil.sh", "x"}], [:memory])

    assert {:error, :unsafe_path} = Unpack.unpack(bytes)
  end
end
```

- [ ] **Step 2: Run tests to verify the dir-entry one fails**

Run: `mix test test/magus/skills/import/unpack_test.exs`
Expected: the "skips zip directory entries" test FAILS (currently `scripts/` appears in files); the limit/traversal tests may already pass (they guard against regressions).

- [ ] **Step 3: Skip directory entries in `from_entries/1`**

In `lib/magus/skills/import/unpack.ex`, reject directory entries (path ends with `/`) before normalization:

```elixir
  defp from_entries(entries) do
    normalized =
      entries
      |> Enum.reject(fn {name, _} -> String.ends_with?(to_string(name), "/") end)
      |> Enum.map(fn {name, content} -> {to_string(name), content} end)
      |> maybe_strip_top_dir()

    # ... rest unchanged ...
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/magus/skills/import/unpack_test.exs`
Expected: PASS (all four).

- [ ] **Step 5: Confirm the artifacts table no longer shows the 0-byte dir row**

The `file_manifest` is derived from `files`; dropping dir entries removes the `scripts/` (0 B, exec) row observed in browser testing. No frontend change needed.

- [ ] **Step 6: Commit**

```bash
git add lib/magus/skills/import/unpack.ex test/magus/skills/import/unpack_test.exs
git commit -m "fix(skills): unpack skips zip directory entries; add unpack limit tests"
```

---

## Task 2: `Magus.Skills.Export` + download serves generated bundle

**Files:**
- Create: `lib/magus/skills/export.ex`
- Modify: `lib/magus/skills/skills.ex` (code interface `export_skill_bundle`)
- Modify: `lib/magus_web/workbench/controllers/skill_controller.ex` (serve export)
- Test: `test/magus/skills/export_test.exs`

**Interfaces:**
- Consumes: `Import.Parser` field names (name/description/license/compatibility/requested_tools/required_secrets/runtime_hints/version/body), `Magus.Files.Storage.get/1` (for artifact files), `Unpack.unpack/1`.
- Produces: `Magus.Skills.Export.generate_bundle/1` (see Shared Interfaces). Round-trips with `Import`.

- [ ] **Step 1: Write the failing round-trip test**

```elixir
# test/magus/skills/export_test.exs
defmodule Magus.Skills.ExportTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.{Export, Import}
  alias Magus.Skills.Import.Parser

  test "export composes a spec-valid SKILL.md and round-trips through import" do
    user = generate(user())

    bytes =
      build_zip([
        {"SKILL.md",
         "---\nname: rt-skill\ndescription: round trip\nlicense: MIT\nallowed-tools: web_search bash\nmetadata:\n  x-magus: '{\"version\":\"1.2.0\",\"required_secrets\":[{\"key\":\"K\"}]}'\n---\nBODY MARKER"},
        {"scripts/go.py", "print(1)"}
      ])

    {:ok, skill} = Import.import_bundle(bytes, actor: user)

    {:ok, zip} = Export.generate_bundle(skill)
    {:ok, %{skill_md: md, files: files}} = Magus.Skills.Import.Unpack.unpack(zip)

    {:ok, attrs} = Parser.parse(md)
    assert attrs.name == "rt-skill"
    assert attrs.description == "round trip"
    assert attrs.license == "MIT"
    assert "web_search" in attrs.requested_tools and "bash" in attrs.requested_tools
    assert attrs.version == "1.2.0"
    assert attrs.body =~ "BODY MARKER"
    assert Enum.any?(files, fn {p, _} -> p == "scripts/go.py" end)
  end

  test "prompt-only skill exports a one-file SKILL.md bundle" do
    user = generate(user())
    {:ok, skill} = Magus.Skills.create_skill(%{name: "p-only", description: "d", body: "hello"}, actor: user)

    {:ok, zip} = Export.generate_bundle(skill)
    {:ok, %{skill_md: md, files: files}} = Magus.Skills.Import.Unpack.unpack(zip)

    assert md =~ "name: p-only"
    assert files == []
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/export_test.exs`
Expected: FAIL (`Magus.Skills.Export` undefined).

- [ ] **Step 3: Create the Export module**

```elixir
# lib/magus/skills/export.ex
defmodule Magus.Skills.Export do
  @moduledoc """
  Generates a spec-valid Anthropic Agent Skills `SKILL.md` bundle from a Skill's
  structured fields plus its stored artifact files. Inverse of `Import.Parser`.
  Always reflects current (edited) state, so it is the single source for the
  download button, marketplace copy, and the file-tree editor's re-pack.
  """

  alias Magus.Skills.Import.Unpack

  @spec generate_bundle(map()) :: {:ok, binary()} | {:error, term()}
  def generate_bundle(skill) do
    with {:ok, artifact_files} <- artifact_files(skill) do
      entries = [{~c"SKILL.md", skill_md(skill)} | artifact_files]

      case :zip.create(~c"skill.zip", entries, [:memory]) do
        {:ok, {_name, bytes}} -> {:ok, bytes}
        {:error, reason} -> {:error, {:zip_failed, reason}}
      end
    end
  end

  # Compose the SKILL.md text: YAML frontmatter (standard fields + x-magus JSON) + body.
  defp skill_md(skill) do
    frontmatter =
      [
        {"name", skill.name},
        {"description", skill.description || ""},
        {"license", skill.license},
        {"compatibility", skill.compatibility},
        {"allowed-tools", allowed_tools(skill.requested_tools)}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "#{k}: #{yaml_scalar(v)}" end)

    x_magus = x_magus(skill)
    metadata_lines = if x_magus, do: ["metadata:", "  x-magus: #{yaml_scalar(x_magus)}"], else: []

    body = skill.body || ""

    """
    ---
    #{Enum.join(frontmatter ++ metadata_lines, "\n")}
    ---
    #{body}
    """
  end

  defp allowed_tools(nil), do: nil
  defp allowed_tools([]), do: nil
  defp allowed_tools(list) when is_list(list), do: Enum.join(list, " ")

  defp x_magus(skill) do
    payload =
      %{}
      |> put_if("version", skill.version)
      |> put_if("required_secrets", nonempty(skill.required_secrets))
      |> put_if("runtime_hints", nonempty_map(skill.runtime_hints))

    if map_size(payload) == 0, do: nil, else: Jason.encode!(payload)
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp nonempty(nil), do: nil
  defp nonempty([]), do: nil
  defp nonempty(list), do: list

  defp nonempty_map(nil), do: nil
  defp nonempty_map(m) when map_size(m) == 0, do: nil
  defp nonempty_map(m), do: m

  # Quote scalars that could confuse YAML (contain ':', quotes, or leading spaces).
  defp yaml_scalar(v) when is_binary(v) do
    if String.match?(v, ~r/[:#'"\n]|^\s|\s$/) do
      ~s(') <> String.replace(v, "'", "''") <> ~s(')
    else
      v
    end
  end

  defp yaml_scalar(v), do: to_string(v)

  # Pull the artifact files out of the stored bundle (prompt-only skills have none).
  defp artifact_files(%{bundle_path: nil}), do: {:ok, []}
  defp artifact_files(%{bundle_path: path}) when is_binary(path) do
    with {:ok, bytes} <- Magus.Files.Storage.get(path),
         {:ok, %{files: files}} <- Unpack.unpack(bytes) do
      {:ok, Enum.map(files, fn {p, content} -> {String.to_charlist(p), content} end)}
    end
  end

  defp artifact_files(_), do: {:ok, []}
end
```

- [ ] **Step 4: Add the code interface**

In `lib/magus/skills/skills.ex`, add a thin domain function (below `sandbox_env_for_user/2`):

```elixir
  @doc "Generate a downloadable SKILL.md bundle from a skill's current fields."
  def export_skill_bundle(skill), do: Magus.Skills.Export.generate_bundle(skill)
```

- [ ] **Step 5: Run the round-trip test**

Run: `mix test test/magus/skills/export_test.exs`
Expected: PASS.

- [ ] **Step 6: Switch the download controller to serve the export**

In `lib/magus_web/workbench/controllers/skill_controller.ex`, replace the `with` body to generate rather than fetch the stored blob:

```elixir
  def download(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with {:ok, skill} <- Magus.Skills.get_skill(id, actor: user),
         {:ok, bytes} <- Magus.Skills.export_skill_bundle(skill) do
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{skill.name}.zip"))
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "Skill bundle not found"})
    end
  end
```

- [ ] **Step 7: Controller test**

```elixir
# test/magus_web/workbench/controllers/skill_controller_test.exs (add or extend)
test "download serves a generated zip for a prompt-only skill", %{conn: conn} do
  user = Magus.Generators.generate(Magus.Generators.user())
  {:ok, skill} = Magus.Skills.create_skill(%{name: "dl", description: "d", body: "b"}, actor: user)

  conn =
    conn
    |> log_in_user(user)   # use the repo's existing auth test helper
    |> get(~p"/skills/#{skill.id}/download")

  assert response_content_type(conn, :zip)
  assert conn.status == 200
  assert byte_size(conn.resp_body) > 0
end
```

> Use the project's existing controller-test auth helper (grep `log_in_user` or the equivalent in `test/support`). If skill download tests already exist, extend that file instead.

- [ ] **Step 8: Run + compile**

Run: `mix test test/magus/skills/export_test.exs test/magus_web/workbench/controllers && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 9: Commit**

```bash
git add lib/magus/skills/export.ex lib/magus/skills/skills.ex lib/magus_web/workbench/controllers/skill_controller.ex test/magus/skills/export_test.exs test/magus_web/workbench/controllers
git commit -m "feat(skills): generate SKILL.md export from fields; download serves it"
```

---

## Task 3: URL import (SSRF-guarded, no git client)

**Files:**
- Create: `lib/magus/skills/import/url_fetcher.ex`
- Modify: `lib/magus_web/rpc/skills_controller.ex` (accept `url`)
- Modify: `frontend/src/lib/ash/api.ts` + the import dialog (accept a URL)
- Test: `test/magus/skills/import/url_fetcher_test.exs`

**Interfaces:**
- Consumes: `Magus.Agents.Tools.Integrations.SsrfValidator.validate_url/1`, `Req`.
- Produces: `Magus.Skills.Import.URLFetcher.fetch/1` (see Shared Interfaces).

- [ ] **Step 1: Write the failing tests (rewrite + guard, stubbed HTTP)**

```elixir
# test/magus/skills/import/url_fetcher_test.exs
defmodule Magus.Skills.Import.URLFetcherTest do
  use ExUnit.Case, async: true
  alias Magus.Skills.Import.URLFetcher

  test "rewrites a github repo URL to a codeload archive URL" do
    assert URLFetcher.archive_url("https://github.com/acme/my-skill") ==
             "https://codeload.github.com/acme/my-skill/zip/refs/heads/main"
  end

  test "leaves a direct .zip URL unchanged" do
    assert URLFetcher.archive_url("https://example.com/bundle.zip") ==
             "https://example.com/bundle.zip"
  end

  test "rejects a private-IP URL before fetching" do
    assert {:error, _} = URLFetcher.fetch("http://127.0.0.1/bundle.zip")
  end

  test "rejects a non-http scheme" do
    assert {:error, _} = URLFetcher.fetch("file:///etc/passwd")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/magus/skills/import/url_fetcher_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Create the fetcher**

```elixir
# lib/magus/skills/import/url_fetcher.ex
defmodule Magus.Skills.Import.URLFetcher do
  @moduledoc """
  Fetches a skill bundle zip over HTTPS. Rewrites GitHub/GitLab repo URLs to
  their archive endpoints (no git client). SSRF-guarded via SsrfValidator; caps
  redirects and body size. Returns raw zip bytes for the standard import pipeline.
  """

  alias Magus.Agents.Tools.Integrations.SsrfValidator

  @max_bytes 25 * 1024 * 1024
  @receive_timeout 30_000

  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(url) when is_binary(url) do
    target = archive_url(url)

    with :ok <- SsrfValidator.validate_url(target),
         {:ok, bytes} <- do_get(target) do
      {:ok, bytes}
    end
  end

  @doc "Rewrite a forge repo URL to a zip-archive URL; pass through direct URLs."
  def archive_url(url) do
    uri = URI.parse(url)

    case {uri.host, String.split(String.trim_leading(uri.path || "", "/"), "/")} do
      {"github.com", [owner, repo | _]} ->
        "https://codeload.github.com/#{owner}/#{strip_git(repo)}/zip/refs/heads/main"

      {"gitlab.com", [owner, repo | _]} ->
        "https://gitlab.com/#{owner}/#{strip_git(repo)}/-/archive/main/#{strip_git(repo)}-main.zip"

      _ ->
        url
    end
  end

  defp strip_git(repo), do: String.replace_suffix(repo, ".git", "")

  defp do_get(url) do
    opts =
      [
        url: url,
        method: :get,
        max_redirects: 3,
        receive_timeout: @receive_timeout,
        connect_options: [timeout: @receive_timeout]
      ]
      |> Keyword.merge(Application.get_env(:magus, :skills_import_req_options, []))

    case Req.request(Req.new(opts)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        cond do
          byte_size(body) > @max_bytes -> {:error, :bundle_too_large}
          not zip?(body) -> {:error, :not_a_zip}
          true -> {:ok, body}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Zip local-file-header magic "PK\x03\x04".
  defp zip?(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: true
  defp zip?(_), do: false
end
```

> Note: the archive rewrite assumes the `main` default branch. If a repo uses `master`, the codeload URL 404s; that surfaces as `{:http_error, 404}` and a clear import error. Trying `master` on 404 is a reasonable follow-up but out of scope here (documented, not silently handled).

- [ ] **Step 4: Wire into the RPC controller**

In `lib/magus_web/rpc/skills_controller.ex`, add a `create/2` head for the URL case (before the `Plug.Upload` head or as a param branch). Keep the file path for uploads:

```elixir
  def create(conn, %{"url" => url} = params) when is_binary(url) and url != "" do
    user = conn.assigns.current_user

    with {:ok, bytes} <- Magus.Skills.Import.URLFetcher.fetch(url),
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
```

- [ ] **Step 5: Run tests + compile**

Run: `mix test test/magus/skills/import/url_fetcher_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 6: Frontend: URL field in the import dialog**

In the skill import dialog (`frontend/src/lib/components/shell/skill-import-dialog.svelte`), add a "From URL" input next to the file picker. Add an `importSkillFromUrl` wrapper to `api.ts`:

```typescript
export async function importSkillFromUrl(url: string, workspaceId?: string): Promise<RpcResult<{ id: string; name: string }>> {
	const body = new URLSearchParams({ url });
	if (workspaceId) body.set('workspace_id', workspaceId);
	try {
		const response = await fetch('/rpc/skills/import', {
			method: 'POST',
			headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
			body,
			credentials: 'same-origin'
		});
		if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
		return (await response.json()) as RpcResult<{ id: string; name: string }>;
	} catch (error) {
		return { success: false, errors: [{ type: 'network_error', message: error instanceof Error ? error.message : 'import failed', shortMessage: 'Network error', vars: {}, fields: [], path: [] }] };
	}
}
```

Wire a submit handler that calls `importSkillFromUrl` and navigates to the created skill on success (mirror the existing upload handler).

- [ ] **Step 7: Frontend check**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json`
Expected: no type errors.

- [ ] **Step 8: Commit**

```bash
git add lib/magus/skills/import/url_fetcher.ex lib/magus_web/rpc/skills_controller.ex frontend/src/lib/ash/api.ts frontend/src/lib/components/shell/skill-import-dialog.svelte test/magus/skills/import/url_fetcher_test.exs
git commit -m "feat(skills): SSRF-guarded URL import with forge archive rewrite"
```

---

## Task 4: AGENTS.md import (prompt-only)

**Files:**
- Create: `lib/magus/skills/import/agents_md.ex`
- Modify: `lib/magus/skills/import.ex` (an `import_agents_md/2` entrypoint) OR the RPC controller
- Modify: `lib/magus_web/rpc/skills_controller.ex` (accept an `agents` file / `agents_url`)
- Test: `test/magus/skills/import/agents_md_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Magus.Skills.Import.AgentsMd.parse/2` returning prompt-only Skill attrs (`source_format: :agents_md`, no bundle fields).

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/import/agents_md_test.exs
defmodule Magus.Skills.Import.AgentsMdTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Skills.Import.AgentsMd

  test "derives a kebab name from the first heading and keeps the full body" do
    md = "# Build Helper\n\nDo the thing carefully."
    {:ok, attrs} = AgentsMd.parse(md, [])

    assert attrs.name == "build-helper"
    assert attrs.description != ""
    assert attrs.body =~ "Do the thing carefully."
    assert attrs.source_format == :agents_md
    refute Map.has_key?(attrs, :bundle_path)
  end

  test "imports as a prompt-only skill (no executable bundle)" do
    user = generate(user())
    md = "# Notes\n\nGuidance text."
    {:ok, attrs} = AgentsMd.parse(md, [])
    {:ok, skill} = Magus.Skills.create_skill(attrs, actor: user)

    assert skill.has_executable_bundle == false
    assert skill.source_format == :agents_md
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/import/agents_md_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Create the adapter**

```elixir
# lib/magus/skills/import/agents_md.ex
defmodule Magus.Skills.Import.AgentsMd do
  @moduledoc """
  Normalizes an AGENTS.md (prompt-only guidance, no scripts) into Skill import
  attrs. Produces a prompt-only skill: body only, source_format :agents_md,
  never any bundle fields.
  """

  @spec parse(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(markdown, opts \\ []) when is_binary(markdown) do
    body = String.trim(markdown)

    if body == "" do
      {:error, :empty}
    else
      name = Keyword.get(opts, :name) || derive_name(body)
      description = first_paragraph(body)

      {:ok,
       %{
         name: name,
         description: description,
         body: body,
         source_format: :agents_md
       }}
    end
  end

  # First markdown heading, kebab-cased to the Skill name charset; fallback to a stable default.
  defp derive_name(body) do
    heading =
      body
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case Regex.run(~r/^#+\s+(.+)$/, String.trim(line)) do
          [_, title] -> title
          _ -> nil
        end
      end)

    (heading || "imported-agents-md")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
    |> case do
      "" -> "imported-agents-md"
      slug -> slug
    end
  end

  defp first_paragraph(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> List.first()
    |> case do
      nil -> "Imported from AGENTS.md"
      line -> String.slice(String.trim(line), 0, 200)
    end
  end
end
```

- [ ] **Step 4: Wire into the RPC controller**

Add a `create/2` head for an AGENTS.md upload (a `.md` file field named `agents`) and for `agents_url`:

```elixir
  def create(conn, %{"agents" => %Plug.Upload{} = upload} = params) do
    user = conn.assigns.current_user

    with {:ok, md} <- File.read(upload.path),
         {:ok, attrs} <- Magus.Skills.Import.AgentsMd.parse(md, []),
         {:ok, skill} <-
           Magus.Skills.create_skill(
             Map.put(attrs, :workspace_id, cast_uuid(params["workspace_id"])),
             actor: user
           ) do
      json(conn, %{success: true, data: %{id: skill.id, name: skill.name}})
    else
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end

  def create(conn, %{"agents_url" => url} = params) when is_binary(url) and url != "" do
    user = conn.assigns.current_user

    with :ok <- Magus.Agents.Tools.Integrations.SsrfValidator.validate_url(url),
         {:ok, %{status: 200, body: md}} when is_binary(md) <- Req.request(Req.new(url: url, max_redirects: 3, receive_timeout: 30_000)),
         {:ok, attrs} <- Magus.Skills.Import.AgentsMd.parse(md, []),
         {:ok, skill} <-
           Magus.Skills.create_skill(Map.put(attrs, :workspace_id, cast_uuid(params["workspace_id"])), actor: user) do
      json(conn, %{success: true, data: %{id: skill.id, name: skill.name}})
    else
      {:ok, %{status: status}} -> json(conn, error_envelope({:http_error, status}))
      {:error, reason} -> json(conn, error_envelope(reason))
    end
  end
```

- [ ] **Step 5: Frontend: accept `.md` in the import dialog**

In `skill-import-dialog.svelte`, allow the file input to accept `.zip,.md` and branch the FormData field name (`agents` for `.md`, `file` for `.zip`). Add the minimal wiring; no new API wrapper is required if you reuse `uploadSkillBundle` with the field name switched (add an `uploadAgentsMd` wrapper mirroring `uploadSkillBundle` but appending `agents`).

- [ ] **Step 6: Run tests + checks**

Run: `mix test test/magus/skills/import/agents_md_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json`
Expected: PASS, clean.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills/import/agents_md.ex lib/magus_web/rpc/skills_controller.ex frontend/src/lib/components/shell/skill-import-dialog.svelte frontend/src/lib/ash/api.ts test/magus/skills/import/agents_md_test.exs
git commit -m "feat(skills): AGENTS.md prompt-only import (file + url)"
```

---

## Task 5: Orphaned-blob cleanup on failed import

**Files:**
- Modify: `lib/magus/skills/import.ex`
- Test: `test/magus/skills/import_cleanup_test.exs`

**Interfaces:**
- Consumes: `Magus.Files.Storage.delete/1`.
- Produces: import deletes the stored blob if the `Skill` row create fails, unless another skill already references that content-addressed path.

- [ ] **Step 1: Write the failing test**

```elixir
# test/magus/skills/import_cleanup_test.exs
defmodule Magus.Skills.ImportCleanupTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "a bundle whose SKILL.md is invalid does not leave an orphaned blob" do
    user = generate(user())

    # Missing name -> Parser rejects AFTER unpack but BEFORE store; ensure the
    # store-then-fail path (create failure) cleans up. Force a create failure by
    # an invalid name that passes the parser but fails the resource validation.
    bytes =
      build_zip([{"SKILL.md", "---\nname: Invalid Name With Spaces\ndescription: d\n---\nb"}, {"scripts/go.py", "x=1"}])

    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    path = "skills/#{user.id}/#{sha}.zip"

    assert {:error, _} = Magus.Skills.Import.import_bundle(bytes, actor: user)
    assert {:error, _} = Magus.Files.Storage.get(path)
  end

  defp build_zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end
end
```

> `Invalid Name With Spaces` passes `Parser` (it only requires a non-empty name) but fails the Skill `:name` validation `~r/^[a-z0-9-]{1,64}$/`, so `import_skill` returns `{:error, ...}` after the blob is stored. That is exactly the orphan case.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/import_cleanup_test.exs`
Expected: FAIL (the blob remains; `Storage.get(path)` returns `{:ok, _}`).

- [ ] **Step 3: Add cleanup to the import pipeline**

In `lib/magus/skills/import.ex`, `do_import_bundle/2`, wrap the create so a post-store failure deletes the blob (only if no other skill references the same content-addressed path):

```elixir
  defp do_import_bundle(zip_bytes, opts) do
    actor = Keyword.fetch!(opts, :actor)
    workspace_id = Keyword.get(opts, :workspace_id)

    sha = sha256_hex(zip_bytes)
    bundle_path = "skills/#{actor.id}/#{sha}.zip"

    with {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(zip_bytes),
         {:ok, manifest_attrs} <- Parser.parse(md),
         {:ok, _} <- Magus.Files.Storage.store(bundle_path, zip_bytes) do
      attrs =
        Map.merge(manifest_attrs, %{
          bundle_path: bundle_path,
          bundle_backend: Magus.Files.Storage.backend_name(),
          bundle_byte_size: byte_size(zip_bytes),
          bundle_sha: sha,
          file_manifest: build_manifest(files),
          has_executable_bundle: Enum.any?(files, fn {p, _} -> String.starts_with?(p, "scripts/") end),
          workspace_id: workspace_id
        })

      case Magus.Skills.import_skill(attrs, actor: actor) do
        {:ok, skill} -> {:ok, skill}
        {:error, reason} -> cleanup_orphan(bundle_path, reason)
      end
    end
  end

  # Delete the just-stored blob when the row create failed, unless another skill
  # already references this content-addressed path (dedup safety).
  defp cleanup_orphan(bundle_path, reason) do
    require Ash.Query

    referenced? =
      Magus.Skills.Skill
      |> Ash.Query.filter(bundle_path == ^bundle_path)
      |> Ash.read!(authorize?: false)
      |> Enum.any?()

    unless referenced?, do: Magus.Files.Storage.delete(bundle_path)
    {:error, reason}
  end
```

- [ ] **Step 4: Run test + compile**

Run: `mix test test/magus/skills/import_cleanup_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/import.ex test/magus/skills/import_cleanup_test.exs
git commit -m "fix(skills): delete orphaned bundle blob when import row create fails"
```

---

## Task 6: `runtime_hints` package preinstall at materialization

**Files:**
- Modify: `lib/magus/skills/materializer.ex`
- Test: `test/magus/skills/materializer_preinstall_test.exs` (unit for the arg builder) + covered by live E2E

**Interfaces:**
- Consumes: `Magus.Sandbox.Orchestrator.install_packages/3`.
- Produces: after file writes + env, the Materializer installs allowlisted packages declared in `runtime_hints`.

- [ ] **Step 1: Write a unit test for the package extraction/validation**

Preinstall runs against the sandbox, so unit-test only the pure package-list builder (validation + allowlist). Extract it as a public function.

```elixir
# test/magus/skills/materializer_preinstall_test.exs
defmodule Magus.Skills.MaterializerPreinstallTest do
  use ExUnit.Case, async: true
  alias Magus.Skills.Materializer

  test "extracts and validates pip + npm package names" do
    hints = %{"pip" => ["requests", "beautifulsoup4"], "npm" => ["left-pad"]}
    assert Materializer.preinstall_plan(hints) == [{:pip, ["requests", "beautifulsoup4"]}, {:npm, ["left-pad"]}]
  end

  test "drops unknown managers and rejects names with shell metacharacters" do
    hints = %{"pip" => ["ok", "bad; rm -rf /"], "cargo" => ["nope"]}
    assert Materializer.preinstall_plan(hints) == [{:pip, ["ok"]}]
  end

  test "empty or nil hints produce no plan" do
    assert Materializer.preinstall_plan(nil) == []
    assert Materializer.preinstall_plan(%{}) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/materializer_preinstall_test.exs`
Expected: FAIL (`preinstall_plan/1` undefined).

- [ ] **Step 3: Implement `preinstall_plan/1` + wire into `write_bundle`**

Add to `lib/magus/skills/materializer.ex`:

```elixir
  @package_name ~r/^[a-zA-Z0-9][a-zA-Z0-9._@\/-]{0,99}$/
  @allowed_managers %{"pip" => :pip, "uv" => :pip, "npm" => :npm}

  @doc false
  # Pure planner: map runtime_hints into an ordered list of {manager, [valid names]}.
  def preinstall_plan(nil), do: []

  def preinstall_plan(hints) when is_map(hints) do
    for {raw_mgr, pkgs} <- hints,
        mgr = Map.get(@allowed_managers, raw_mgr),
        not is_nil(mgr),
        valid = Enum.filter(List.wrap(pkgs), &(is_binary(&1) and Regex.match?(@package_name, &1))),
        valid != [] do
      {mgr, valid}
    end
  end

  def preinstall_plan(_), do: []
```

Extend `write_bundle/5` to run the plan after env, before the marker (failures are logged, not fatal):

```elixir
  defp write_bundle(conversation_id, skill, user_id, dir, marker) do
    with {:ok, bytes} <- Magus.Files.Storage.get(skill.bundle_path),
         {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(bytes),
         :ok <- write_all(conversation_id, dir, [{"SKILL.md", md} | files], user_id),
         :ok <- ensure_env(conversation_id, skill, user_id),
         :ok <- run_preinstall(conversation_id, skill, user_id),
         {:ok, _} <- Orchestrator.write_file(conversation_id, marker, "ok", user_id: user_id) do
      {:ok, dir}
    end
  end

  defp run_preinstall(conversation_id, skill, user_id) do
    for {mgr, packages} <- preinstall_plan(skill.runtime_hints) do
      case mgr do
        :pip ->
          Orchestrator.install_packages(conversation_id, packages, user_id: user_id, timeout_ms: 120_000)

        :npm ->
          # npm install runs as a command since install_packages targets pip/uv.
          cmd = "npm install --no-save " <> Enum.join(packages, " ")
          Orchestrator.run_command(conversation_id, cmd, user_id: user_id, timeout_ms: 120_000)
      end
      |> case do
        {:ok, _} -> :ok
        other -> Logger.warning("skill preinstall #{mgr} failed: #{inspect(other)}")
      end
    end

    :ok
  end
```

> Confirm the exact Orchestrator entrypoint for arbitrary commands during implementation. The recon shows `install_packages/3` (uv pip) and a `CommandRunner.run/3`; if there is no `Orchestrator.run_command/3`, call the `CommandRunner` path the sandbox tools use (grep `RunCode`/`ExecCommand`), and adjust the npm branch accordingly. Package names are validated to the `@package_name` charset, so even the string-joined npm command carries no shell metacharacters.

- [ ] **Step 4: Run unit test + compile**

Run: `mix test test/magus/skills/materializer_preinstall_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 5: Commit**

```bash
git add lib/magus/skills/materializer.ex test/magus/skills/materializer_preinstall_test.exs
git commit -m "feat(skills): preinstall runtime_hints packages at materialization (allowlisted, argv-safe)"
```

---

## Task 7: Carry-overs (discovery cache, sentinel idempotency, nil-actor log)

**Files:**
- Modify: `lib/magus/skills/discovery.ex` (per-turn cache)
- Modify: `lib/magus/skills/loader.ex` (sentinel marker; nil-actor log)
- Test: `test/magus/skills/discovery_cache_test.exs`

**Interfaces:**
- Produces: `Discovery.list_for_actor/1` reads user skills at most once per turn (process cache); `Loader` uses a sentinel marker for idempotency and logs nil-actor loads distinctly.

- [ ] **Step 1: Write the failing cache test**

```elixir
# test/magus/skills/discovery_cache_test.exs
defmodule Magus.Skills.DiscoveryCacheTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  alias Magus.Skills.Discovery

  test "within one turn, repeated list_for_actor hits the process cache" do
    user = generate(user())
    {:ok, _} = Magus.Skills.create_skill(%{name: "c-skill", description: "d", body: "b"}, actor: user)

    Discovery.with_turn_cache(fn ->
      a = Discovery.list_for_actor(user)
      b = Discovery.list_for_actor(user)
      assert a == b
      # The cache marker is present during the turn.
      assert Process.get(:skills_discovery_cache) != nil
    end)

    # Cleared after the turn.
    assert Process.get(:skills_discovery_cache) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/magus/skills/discovery_cache_test.exs`
Expected: FAIL (`Discovery.with_turn_cache/1` undefined).

- [ ] **Step 3: Add the per-turn cache**

In `lib/magus/skills/discovery.ex`, wrap the user-skills read in an opt-in process cache. The preflight/system-prompt path calls `with_turn_cache/1` once per turn.

```elixir
  @cache_key :skills_discovery_cache

  @doc """
  Run `fun` with a per-process discovery cache active, clearing it after. The
  system-prompt/preflight path wraps a turn so repeated list_for_actor calls
  do one authorized read instead of one per section composition.
  """
  def with_turn_cache(fun) do
    Process.put(@cache_key, %{})
    try do
      fun.()
    after
      Process.delete(@cache_key)
    end
  end

  defp cached_user_views(actor, compute) do
    case Process.get(@cache_key) do
      nil ->
        compute.()

      cache ->
        key = actor && actor.id

        case Map.fetch(cache, key) do
          {:ok, views} ->
            views

          :error ->
            views = compute.()
            Process.put(@cache_key, Map.put(cache, key, views))
            views
        end
    end
  end
```

Route `user_views/1` through it:

```elixir
  defp user_views(nil), do: []

  defp user_views(actor) do
    cached_user_views(actor, fn -> compute_user_views(actor) end)
  end

  defp compute_user_views(actor) do
    case Magus.Skills.list_skills(actor: actor) do
      {:ok, skills} ->
        Enum.map(skills, fn s ->
          %{
            ref: "user:" <> s.id,
            name: s.name,
            description: s.description || "",
            source: :user,
            has_executable_bundle: s.has_executable_bundle,
            runnable: not s.has_executable_bundle or Magus.Sandbox.Provider.configured?()
          }
        end)

      {:error, err} ->
        Logger.warning("Skills.Discovery: failed to list user skills: #{inspect(err)}")
        []
    end
  end
```

- [ ] **Step 4: Wrap the turn in the system-prompt/preflight path**

Find where the discovery-backed skills section is composed for the system prompt (grep `Discovery.list_for_actor`) and wrap that turn's composition in `Discovery.with_turn_cache/1`. If the system prompt and preflight both call it in the same turn, wrap the outermost boundary (the ReAct turn builder). Document the wrap site in the commit.

- [ ] **Step 5: Sentinel idempotency + nil-actor log in the Loader**

In `lib/magus/skills/loader.ex`, replace the substring-based `persist_user_skill` idempotency with a sentinel marker line that encodes the ref (and sha for bundled). Prepend a marker when persisting and check for it:

```elixir
  defp persist_user_skill(context, skill, body, tools) do
    body = body || ""
    marker = "<!-- magus:skill user:#{skill.id}@#{skill.bundle_sha || "prompt"} -->"
    content = marker <> "\n" <> body

    persist_context_and_tools(context, content, tools, fn existing_context, _existing_tools ->
      String.contains?(existing_context, marker)
    end)
  end
```

Update the `{:user, skill}` branch in `load/3` to call `persist_user_skill(context, skill, skill.body, tools)` (threading the skill so the marker has the id + sha).

Add a distinct nil-actor log where a bundled skill loads without a user (autonomy):

```elixir
  defp materialize(context, skill, base, tools, conversation_id, user_id) do
    if is_nil(user_id) do
      Logger.info("skills: materializing #{skill.name} with no acting user (autonomy path)")
    end
    # ... unchanged ...
  end
```

- [ ] **Step 6: Run tests + compile**

Run: `mix test test/magus/skills/discovery_cache_test.exs test/magus/skills/loader_test.exs && MIX_ENV=test mix compile --warnings-as-errors`
Expected: PASS, clean.

- [ ] **Step 7: Commit**

```bash
git add lib/magus/skills/discovery.ex lib/magus/skills/loader.ex test/magus/skills/discovery_cache_test.exs
git commit -m "perf(skills): per-turn discovery cache; sentinel-marker load idempotency; nil-actor log"
```

---

## Task 8: Live E2E for import round-trip + preinstall

**Files:**
- Create: `test/e2e_live/skills_exchange_test.exs`

- [ ] **Step 1: Write the E2E test (sandbox-tagged)**

```elixir
# test/e2e_live/skills_exchange_test.exs
defmodule Magus.LiveE2E.SkillsExchangeTest do
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Tools.Sandbox.RunCode

  @moduletag :sandbox
  @moduletag timeout: 240_000

  setup %{user: user, model: model} do
    conversation = create_conversation(user, model)
    context = %{conversation_id: conversation.id, user_id: user.id, user: user}
    {:ok, probe} = RunCode.run(%{"code" => "print('probe')"}, context)
    %{user: user, conversation: conversation, sandbox?: probe[:success] == true}
  end

  test "export -> reimport preserves the runnable skill; preinstall installs a package",
       %{user: user, conversation: conversation, sandbox?: sandbox?} do
    if sandbox? do
      bytes =
        build_zip([
          {"SKILL.md",
           "---\nname: ex-skill\ndescription: d\nmetadata:\n  x-magus: '{\"runtime_hints\":{\"pip\":[\"cowsay\"]}}'\n---\nrun scripts/moo.py"},
          {"scripts/moo.py", "import cowsay\ncowsay.cow('hi')"}
        ])

      {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: user)
      {:ok, zip} = Magus.Skills.export_skill_bundle(skill)
      {:ok, reimported} = Magus.Skills.Import.import_bundle(zip, actor: user)
      assert reimported.name == "ex-skill"
      assert reimported.has_executable_bundle

      # Approve + materialize triggers preinstall of cowsay.
      {:ok, _} =
        Magus.Skills.record_conversation_approval(
          %{conversation_id: conversation.id, skill_id: reimported.id, bundle_sha: reimported.bundle_sha, approved_by_id: user.id, source: :approval_card},
          authorize?: false
        )

      {:ok, c} = Magus.Chat.get_conversation(conversation.id, authorize?: false)
      {:ok, _dir} = Magus.Skills.Materializer.materialize(conversation.id, reimported, user.id)

      {:ok, run} = RunCode.run(%{"code" => "import cowsay; print('ok')"}, %{conversation_id: conversation.id, user_id: user.id, user: user})
      assert run[:success] == true
      _ = c
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

Run: `bin/test-e2e-live test/e2e_live/skills_exchange_test.exs --include sandbox`
Expected: 1 test, 0 failures (or clean skip without creds).

- [ ] **Step 3: Commit**

```bash
git add test/e2e_live/skills_exchange_test.exs
git commit -m "test(skills): live E2E for export round-trip + runtime_hints preinstall"
```

---

## Task 9: Full-suite gate

- [ ] **Step 1: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 2: Backend blast radius**

Run: `mix test test/magus/skills test/magus_web/workbench/controllers test/magus_web/rpc`
Expected: PASS (scope assertions to seeded rows per the shared-DB caveat).

- [ ] **Step 3: Frontend**

Run: `cd frontend && npx svelte-check --tsconfig ./tsconfig.json`
Expected: no type errors. Regenerate types off-server if any RPC changed and commit.

- [ ] **Step 4: Commit (only if regen changed generated files)**

```bash
git add frontend/src/lib/ash/ash_rpc.ts frontend/src/lib/ash/ash_types.ts
git commit -m "chore(skills): regenerate RPC types for phase 2b"
```

---

## Notes for the executor

- **Depends on Plan 2A** for `bundle_sha`. Export sets a filename from `skill.name`; the download switch relies on `export_skill_bundle/1`.
- **SSRF is non-negotiable**: every outbound fetch (URL import, AGENTS.md URL) goes through `SsrfValidator.validate_url/1` first. Do not add a fetch path that skips it.
- **Preinstall argv safety**: package names are validated against `@package_name`; never build an install command by interpolating unvalidated names into a shell string. Confirm the real Orchestrator command entrypoint during implementation (recon shows `install_packages/3` for pip/uv; verify the npm path).
- **Req test injection**: `URLFetcher` reads `Application.get_env(:magus, :skills_import_req_options, [])` so tests can stub the transport with `Req.Test` (mirror `config/test.exs`'s Daytona stub). Add that config key in `config/test.exs` if you want the fetch path covered without real network.
- **`master` default branch**: the forge rewrite assumes `main`; a `master`-default repo yields a 404 import error (documented, not silently retried).
