# User-Managed Skills — SPA UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Skills" mode to the SvelteKit SPA so users can browse, author, import (zip bundle), share, and delete user-managed skills, plus a one-click in-chat approval card for the bundled-skill first-run gate and a bundle artifacts view/download.

**Architecture:** The skills UI mirrors the existing **prompts** feature almost 1:1 (SvelteKit file-based routes, a Svelte-5-runes nav store, thin `api.ts` RPC wrappers over the already-generated `ash_rpc.ts` client). Two paths create skills: the `create_skill` RPC action (prompt-only / simple authoring) and a multipart `uploadSkillBundle` to the existing `/rpc/skills/import` controller (zip bundles). The approval card rides on the SPA's existing notification surface (`approval_request` notifications already arrive via the `user:{id}` Phoenix channel) and sends the `approve_phrase` as a normal user message. Artifact download reuses the `/files/:id/download` controller pattern as a new `GET /skills/:id/download` route. The backend (Phase 1A+1B+1C) is complete and merge-ready; the only new backend code here is the bundle-download controller.

**Tech Stack:** SvelteKit 2 + Svelte 5 (runes: `$state`/`$derived`/`$effect`), Tailwind + shadcn-svelte, the AshTypescript RPC client (`frontend/src/lib/ash/`), Vitest (unit), Playwright (E2E). Backend: Phoenix controller (Elixir).

## Plan sequence (context)

This is the **UI layer** of the user-managed skills feature. It depends on the merged backend: the `Magus.Skills` domain with RPC actions (`my_skills`, `workspace_skills`, `get_skill`, `create_skill`, `update_skill`, `destroy_skill`, `share_skill_to_team`, `unshare_skill_from_team`) exposed in `lib/magus/skills/skills.ex` and codegen'd into `frontend/src/lib/ash/ash_rpc.ts` (Phase 1A), the `/rpc/skills/import` multipart controller (Phase 1C-import), and the `approval_request` notification carrying `metadata.approve_phrase` (Phase 1C-runtime). Tasks are ordered so the first five deliver a usable **browse + import** experience; the rest add authoring, the approval card, and artifacts.

## Global Constraints

- **Mirror prompts, do not reinvent.** The prompts feature is the concrete template. For each skills file, clone the named prompts file and apply the listed deltas. Match its Svelte-5-runes style, Tailwind/`wb-*` classes, and `data-testid` conventions.
- **Never edit generated files.** `frontend/src/lib/ash/ash_rpc.ts` and `ash_types.ts` are generated (`mix ash_typescript.codegen`). Only edit `frontend/src/lib/ash/api.ts` (the app wrapper) and feature files. If a needed `rpc.skill*` function is missing from `ash_rpc.ts`, regenerate via `set -a && source .env && set +a && mix ash_typescript.codegen` (run from repo root) and commit the regenerated file; do NOT hand-edit it.
- **RPC result shape:** all `api.ts` wrappers return `RpcResult<T>` = `{ success: true, data: T } | { success: false, errors: RpcError[] }`. Follow the existing prompt wrappers exactly (field selection + `run(...)` helper at `frontend/src/lib/ash/api.ts:49`).
- **Auth:** custom `fetch` (multipart upload, bundle download link) uses `credentials: 'same-origin'`; check `response.status === 401` → return the `UNAUTHENTICATED` error, mirroring `uploadFile` (`api.ts:1777`).
- **SPA base path:** routes are served under a base (E2E navigates to `/next/skills`); use the same `base`/link helpers the prompts routes use (do not hardcode `/skills` where prompts uses a base-aware helper).
- **No em dashes** in code or copy. German copy, if any, uses informal address (none expected here; copy is English).
- **Frontend commands (run from `frontend/`):** typecheck `npm run check`; unit tests `npm run test:unit` (Vitest); E2E `npm run test:e2e` (Playwright). Confirm the exact script names in `frontend/package.json` before running; use whatever that file defines. Backend task uses `set -a && source .env && set +a && MIX_ENV=test mix test <path>` and `... mix compile --warnings-as-errors` from the repo root.
- **Worktree:** work in `/Users/daniel/Development/magus/.claude/worktrees/user-managed-skills-1a` (branch `worktree-user-managed-skills-1a`). Do not `cd` out of it. The frontend has its own `node_modules` (symlinked per worktree setup).

## File Structure

**New backend:**
- `lib/magus_web/workbench/controllers/skill_controller.ex` — `download/2` action serving the stored bundle zip.
- `lib/magus_web/core_router.ex` (modify) — add `get "/skills/:id/download", SkillController, :download`.

**New frontend (mirroring prompts):**
- `frontend/src/lib/ash/api.ts` (modify) — skill RPC wrappers + `uploadSkillBundle` + `skillDownloadUrl` + types.
- `frontend/src/lib/stores/skills-nav.svelte.ts` — scope store (clone of `prompts-nav.svelte.ts`).
- `frontend/src/lib/components/shell/mode-strip.svelte` (modify) — add the `skills` mode.
- `frontend/src/lib/components/shell/nav-pane.svelte` (modify) — `skills` mode primary actions (New skill / Import skill).
- `frontend/src/lib/components/shell/skills-nav.svelte` — scope/tag rail (clone of `prompts-nav.svelte`).
- `frontend/src/lib/workbench/*` (modify) — add `'skills'` to the `WorkbenchMode` union and `MODE_HOME` (find the type's source).
- `frontend/src/routes/skills/+layout.svelte`, `+page.svelte`, `[skillId]/+page.svelte`, `components/skill-gallery.svelte`, `components/skill-card.svelte` — clones of the prompts route files.
- `frontend/src/routes/skills/components/skill-import-dialog.svelte` — zip upload dialog.
- `frontend/src/lib/components/chat/approval-card.svelte` (or an addition to `notification-bell.svelte`) — the approval action card.
- `frontend/tests/skills.spec.ts` — Playwright E2E.
- `frontend/src/lib/stores/skills-nav.test.ts` — Vitest unit (if the store has partition logic worth unit-testing).

---

### Task 1: Backend — skill bundle download endpoint

**Files:**
- Create: `lib/magus_web/workbench/controllers/skill_controller.ex`
- Modify: `lib/magus_web/core_router.ex` (add the route near `get "/files/:id/download", FileController, :download`)
- Test: `test/magus_web/skill_controller_test.exs`

**Interfaces:**
- Produces: `GET /skills/:id/download` — session-authenticated; authorizes via `Magus.Skills.get_skill(id, actor: current_user)`; streams the stored bundle zip with `content-disposition: attachment; filename="<name>.zip"`. 404 when the skill is not found/authorized or the bundle is missing.

- [ ] **Step 1: Read the reference controller**

Read `lib/magus_web/workbench/controllers/resource_controller.ex` (the `download/2` for files, ~lines 71-133) and how it calls `Magus.Files.Storage` + sets the disposition header. Read the router line `get "/files/:id/download", FileController, :download` (`core_router.ex:243`) and note which `scope`/`pipeline` it sits in (the browser-auth pipeline, not `:rpc`).

- [ ] **Step 2: Write the failing test**

Create `test/magus_web/skill_controller_test.exs`:

```elixir
defmodule MagusWeb.Workbench.SkillControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  defp zip(entries) do
    files = Enum.map(entries, fn {p, c} -> {String.to_charlist(p), c} end)
    {:ok, {_n, bytes}} = :zip.create(~c"b.zip", files, [:memory])
    bytes
  end

  test "downloads a skill bundle as an attachment", %{conn: conn} do
    owner = generate(user())
    bytes = zip([{"SKILL.md", "---\nname: dl-skill\ndescription: d\n---\nbody"}, {"scripts/go.py", "print(1)"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    conn =
      conn
      |> log_in_user(owner)
      |> get(~p"/skills/#{skill.id}/download")

    assert response(conn, 200) == bytes
    assert {"content-disposition", disp} = List.keyfind(conn.resp_headers, "content-disposition", 0)
    assert disp =~ "attachment"
    assert disp =~ "dl-skill.zip"
  end

  test "404 for a skill the user cannot access", %{conn: conn} do
    owner = generate(user())
    stranger = generate(user())
    bytes = zip([{"SKILL.md", "---\nname: priv-skill\ndescription: d\n---\nb"}])
    {:ok, skill} = Magus.Skills.Import.import_bundle(bytes, actor: owner)

    conn = conn |> log_in_user(stranger) |> get(~p"/skills/#{skill.id}/download")
    assert conn.status == 404
  end
end
```

(Confirm `~p"/skills/#{id}/download"` resolves once the route exists; confirm `log_in_user/2` import location matches `skills_controller_test.exs` from Phase 1C-import. If the file controller test uses a different login helper, match it.)

- [ ] **Step 3: Run the test to verify it fails**

Run: `set -a && source .env && set +a && MIX_ENV=test mix test test/magus_web/skill_controller_test.exs`
Expected: FAIL (route/controller undefined).

- [ ] **Step 4: Create the controller**

Create `lib/magus_web/workbench/controllers/skill_controller.ex` (mirror `resource_controller.ex`'s download + disposition helper):

```elixir
defmodule MagusWeb.Workbench.SkillController do
  @moduledoc """
  Serves a skill's stored bundle zip as a download (`GET /skills/:id/download`).
  Session-authenticated; authorization is delegated to `Magus.Skills.get_skill/2`
  with the current user as actor. Mirrors the Files download controller.
  """
  use MagusWeb, :controller

  def download(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, skill} <- Magus.Skills.get_skill(id, actor: user),
         path when is_binary(path) <- skill.bundle_path,
         {:ok, bytes} <- Magus.Files.Storage.get(path) do
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{skill.name}.zip")
      )
      |> send_resp(200, bytes)
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "Skill bundle not found"})
    end
  end
end
```

(If `resource_controller.ex` uses a shared `content_disposition/2` helper or `Plug.Conn.put_resp_header` differently, mirror its exact approach. The `with` first clause `{:ok, skill}` covers not-found/unauthorized via `get_skill`; the `path when is_binary` clause covers a prompt-only skill with `bundle_path == nil` → 404.)

- [ ] **Step 5: Add the route**

In `lib/magus_web/core_router.ex`, alongside `get "/files/:id/download", FileController, :download` (same scope/pipeline — the browser-authenticated one, NOT `:rpc`), add:

```elixir
    get "/skills/:id/download", MagusWeb.Workbench.SkillController, :download
```

(Use the alias form matching how `FileController` is referenced in that scope.)

- [ ] **Step 6: Run the test, compile check, commit**

```bash
set -a && source .env && set +a && MIX_ENV=test mix test test/magus_web/skill_controller_test.exs
set -a && source .env && set +a && MIX_ENV=test mix compile --warnings-as-errors
git add lib/magus_web/workbench/controllers/skill_controller.ex lib/magus_web/core_router.ex test/magus_web/skill_controller_test.exs
git commit -m "feat(skills): GET /skills/:id/download bundle endpoint"
```

---

### Task 2: SPA data layer — skill RPC wrappers, upload, download URL

**Files:**
- Modify: `frontend/src/lib/ash/api.ts` (add a "Skills" section mirroring the "Prompts" section at ~lines 2491-2588)

**Interfaces:**
- Produces (exported from `api.ts`): `mySkills()`, `workspaceSkills(workspaceId)`, `getSkill(id)`, `createSkill(input)`, `updateSkill(id, input)`, `destroySkill(id)`, `shareSkillToTeam(id)`, `unshareSkillFromTeam(id)`, `uploadSkillBundle(file, workspaceId?)`, `skillDownloadUrl(skill)`. Types: `SkillSummary`, `SkillDetail` (mirroring `PromptSummary`/`PromptDetail`).

- [ ] **Step 1: Read the reference + confirm generated functions**

Read the Prompts section of `frontend/src/lib/ash/api.ts` (~2491-2588: `myPrompts`, `getPrompt`, `createPrompt`, `updatePrompt`, `destroyPrompt`, `sharePromptToTeam`, etc.) and the `uploadFile` function (~1777-1814). Confirm `ash_rpc.ts` exports skill functions: `grep -n "skill" frontend/src/lib/ash/ash_rpc.ts` — expect `mySkills`/`workspaceSkills`/`createSkill`/`updateSkill`/`destroySkill`/`getSkill`/`shareSkillToTeam`/`unshareSkillFromTeam` (names match the `rpc_action` names in `lib/magus/skills/skills.ex`). If any are missing, regenerate: `set -a && source .env && set +a && mix ash_typescript.codegen` (repo root) and commit `ash_rpc.ts`.

- [ ] **Step 2: Add the Skills wrappers**

In `api.ts`, add a Skills section. Mirror each prompt wrapper, swapping the rpc function and the field selection. The field selection must include the columns the UI needs: `id, name, displayName, description, body, requestedTools, requiredSecrets, runtimeHints, version, license, sourceFormat, hasExecutableBundle, bundleByteSize, fileManifest, isSharedToWorkspace, workspaceId, userId, insertedAt, updatedAt` (use the exact camelCase field names the generated client exposes; confirm against `ash_types.ts`). Example shape (adapt to the real `run`/selection helper):

```typescript
// ─── Skills ───────────────────────────────────────────────────────────
export async function mySkills(): Promise<RpcResult<SkillSummary[]>> {
  return run((opts) => rpc.mySkills({ fields: SKILL_SUMMARY_FIELDS, ...opts }));
}

export async function getSkill(id: string): Promise<RpcResult<SkillDetail>> {
  return run((opts) => rpc.getSkill({ input: { id }, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export async function createSkill(input: CreateSkillInput): Promise<RpcResult<SkillDetail>> {
  return run((opts) => rpc.createSkill({ input, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export async function updateSkill(id: string, input: UpdateSkillInput): Promise<RpcResult<SkillDetail>> {
  return run((opts) => rpc.updateSkill({ primaryKey: id, input, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export async function destroySkill(id: string): Promise<RpcResult<void>> {
  return run((opts) => rpc.destroySkill({ primaryKey: id, ...opts }));
}

export async function shareSkillToTeam(id: string): Promise<RpcResult<SkillDetail>> {
  return run((opts) => rpc.shareSkillToTeam({ primaryKey: id, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export async function unshareSkillFromTeam(id: string): Promise<RpcResult<SkillDetail>> {
  return run((opts) => rpc.unshareSkillFromTeam({ primaryKey: id, fields: SKILL_DETAIL_FIELDS, ...opts }));
}
```

(The EXACT call shape — `input` vs `primaryKey`, `fields` selection — must match how the prompt wrappers call `rpc.updatePrompt`/`rpc.destroyPrompt`. Copy that calling convention verbatim; only the function name and field set change.)

- [ ] **Step 3: Add the multipart upload + download URL helper**

```typescript
export async function uploadSkillBundle(
  file: File,
  workspaceId?: string
): Promise<RpcResult<{ id: string; name: string }>> {
  const form = new FormData();
  form.append("file", file);
  if (workspaceId) form.append("workspace_id", workspaceId);

  const response = await fetch("/rpc/skills/import", {
    method: "POST",
    body: form,
    credentials: "same-origin"
  });
  if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
  return (await response.json()) as RpcResult<{ id: string; name: string }>;
}

export function skillDownloadUrl(skill: { id: string }): string {
  return `/skills/${skill.id}/download`;
}
```

(Mirror `uploadFile`'s structure exactly, including the `UNAUTHENTICATED` constant and the `RpcResult` JSON parse. The import controller returns `{success, data: {id, name}}` / `{success, errors}` already.)

- [ ] **Step 4: Add the types**

Define `SkillSummary`, `SkillDetail`, `CreateSkillInput`, `UpdateSkillInput`, and the field-selection constants (`SKILL_SUMMARY_FIELDS`, `SKILL_DETAIL_FIELDS`) following the `PromptSummary`/`PromptDetail` patterns. Reuse generated types from `ash_types.ts` where possible (e.g. a generated `Skill` type) rather than hand-rolling.

- [ ] **Step 5: Typecheck and commit**

```bash
cd frontend && npm run check   # (run from frontend/; confirm the script name in package.json)
git add frontend/src/lib/ash/api.ts frontend/src/lib/ash/ash_rpc.ts
git commit -m "feat(skills/spa): api.ts skill RPC wrappers, bundle upload, download URL"
```

(Commit `ash_rpc.ts` only if it was regenerated in Step 1.)

---

### Task 3: Skills nav store

**Files:**
- Create: `frontend/src/lib/stores/skills-nav.svelte.ts`
- Test: `frontend/src/lib/stores/skills-nav.test.ts`

**Interfaces:**
- Consumes: `mySkills()`, `workspaceSkills(workspaceId)` (Task 2).
- Produces: a `skillsNav` singleton (class with `$state`) exposing `personal`, `shared`, `workspace` arrays of `SkillSummary`, a `loading` flag, `load(workspaceId, force?)`, and `refresh()`. Mirrors `prompts-nav.svelte.ts`.

- [ ] **Step 1: Read the reference**

Read `frontend/src/lib/stores/prompts-nav.svelte.ts` fully. Note its partition logic (favorites/shared/personal) and how `load` fetches and how `refresh` re-fetches.

- [ ] **Step 2: Write the failing unit test**

Skills have no "favorites" action, so the partition is by ownership/sharing. Create `frontend/src/lib/stores/skills-nav.test.ts` testing the pure partition helper (extract one if `prompts-nav` has it; otherwise test `load` with a mocked `mySkills`). Example (adapt to how prompts-nav is tested, if it is):

```typescript
import { describe, expect, it, vi } from "vitest";
import { partitionSkills } from "./skills-nav.svelte";

describe("partitionSkills", () => {
  it("splits personal (no workspace) from shared/workspace", () => {
    const skills = [
      { id: "1", name: "a", workspaceId: null, isSharedToWorkspace: false },
      { id: "2", name: "b", workspaceId: "ws", isSharedToWorkspace: true }
    ] as any;
    const { personal, workspace } = partitionSkills(skills, "ws");
    expect(personal.map((s) => s.id)).toEqual(["1"]);
    expect(workspace.map((s) => s.id)).toEqual(["2"]);
  });
});
```

(If `prompts-nav.svelte.ts` does partitioning inline without an exported helper, EXTRACT a pure `partitionSkills` function in the skills store so it is unit-testable, and keep the store class thin around it.)

- [ ] **Step 3: Run the test to verify it fails**

Run (from `frontend/`): `npm run test:unit -- skills-nav` — expect FAIL (module/function missing).

- [ ] **Step 4: Implement the store**

Clone `prompts-nav.svelte.ts` → `skills-nav.svelte.ts`, replacing prompt RPC calls with `mySkills`/`workspaceSkills`, dropping the favorites partition, and exporting the pure `partitionSkills`. Keep the singleton export pattern (`export const skillsNav = new SkillsNav()`).

- [ ] **Step 5: Run the test to verify it passes + commit**

```bash
cd frontend && npm run test:unit -- skills-nav
git add frontend/src/lib/stores/skills-nav.svelte.ts frontend/src/lib/stores/skills-nav.test.ts
git commit -m "feat(skills/spa): skills nav store with partition logic"
```

---

### Task 4: Skills mode wiring (mode-strip, MODE_HOME, WorkbenchMode, nav-pane)

**Files:**
- Modify: the `WorkbenchMode` type source (find it: `grep -rn "WorkbenchMode" frontend/src/lib` — likely `frontend/src/lib/workbench/*` or `stores/workbench.svelte.ts`)
- Modify: `frontend/src/lib/components/shell/mode-strip.svelte`
- Modify: `frontend/src/lib/components/shell/nav-pane.svelte`
- Create: `frontend/src/lib/components/shell/skills-nav.svelte` (scope rail)

**Interfaces:**
- Produces: a `skills` entry in the mode strip (icon + label) routing to `/skills`; sidebar primary actions in skills mode ("New skill", "Import skill"); a skills scope rail. Consumes `skillsNav` (Task 3).

- [ ] **Step 1: Add `'skills'` to the mode union + home route**

In the `WorkbenchMode` type, add `'skills'`. In `mode-strip.svelte`, add to the `modes` array (line ~30): `{ key: 'skills', label: 'Skills', icon: <a Lucide icon, e.g. Wrench or Boxes> }` (import the icon). In `MODE_HOME` (line ~38): `skills: '/skills'`.

- [ ] **Step 2: Sidebar primary actions**

In `nav-pane.svelte`, find the prompts-mode branch (`workbench.mode === 'prompts'`, ~line 127) that renders "New prompt". Add a sibling branch for `workbench.mode === 'skills'` rendering two actions: "New skill" (opens the create form / new-skill route) and "Import skill" (opens the import dialog from Task 8). Wire the scope rail: where prompts render `<PromptsNav />`, add a `skills` branch rendering `<SkillsNav />`.

- [ ] **Step 3: Skills scope rail**

Clone `frontend/src/lib/components/shell/prompts-nav.svelte` → `skills-nav.svelte`, swapping the store to `skillsNav` and the scopes to All / Personal / Shared / Workspace (drop Favorites). Filter the gallery via `?scope=` URL params the same way prompts-nav does. Add `data-testid="skills-nav"`.

- [ ] **Step 4: Typecheck + commit**

```bash
cd frontend && npm run check
git add frontend/src/lib/components/shell/mode-strip.svelte frontend/src/lib/components/shell/nav-pane.svelte frontend/src/lib/components/shell/skills-nav.svelte frontend/src/lib/<workbench-mode-type-file>
git commit -m "feat(skills/spa): skills mode in nav, mode-strip, and scope rail"
```

---

### Task 5: Skills routes — gallery, card, layout, index (browse)

**Files:**
- Create: `frontend/src/routes/skills/+layout.svelte`, `frontend/src/routes/skills/+page.svelte`
- Create: `frontend/src/routes/skills/components/skill-gallery.svelte`, `frontend/src/routes/skills/components/skill-card.svelte`

**Interfaces:**
- Produces: the `/skills` browse experience (master-detail shell + gallery grid). Consumes `skillsNav` and `mySkills`. Each card links to `/skills/<id>`.

- [ ] **Step 1: Clone the prompts route shell**

Clone `frontend/src/routes/prompts/+layout.svelte` → `skills/+layout.svelte` and `prompts/+page.svelte` → `skills/+page.svelte`, swapping `prompts` → `skills`, the store, and the link base. Keep the master-detail split.

- [ ] **Step 2: Clone the gallery + card**

Clone `prompts/components/prompt-gallery.svelte` → `skills/components/skill-gallery.svelte` and `prompt-card.svelte` → `skill-card.svelte`. Deltas:
- Data source → `skillsNav` / `mySkills`.
- Card shows: name, description, a `requested tools` count, and a **runnable badge**: if `hasExecutableBundle` is true, show a "needs sandbox" / "runnable" indicator (use the `runnable` info — the card can show a "code" chip when `hasExecutableBundle`). Add `data-testid="skill-card"` and `data-testid="skill-gallery"`.
- "New skill" and "Import skill" buttons (wired in Task 4/8) — the gallery's empty state should point to both.

- [ ] **Step 3: Typecheck + manual smoke**

```bash
cd frontend && npm run check
```
(Optional: `npm run dev` and click into Skills to eyeball the gallery; not required for commit.)

- [ ] **Step 4: Commit**

```bash
git add frontend/src/routes/skills/+layout.svelte frontend/src/routes/skills/+page.svelte frontend/src/routes/skills/components/skill-gallery.svelte frontend/src/routes/skills/components/skill-card.svelte
git commit -m "feat(skills/spa): skills browse gallery and cards"
```

---

### Task 6: Skill detail — read view, manifest/artifacts, download

**Files:**
- Create: `frontend/src/routes/skills/[skillId]/+page.svelte`

**Interfaces:**
- Consumes: `getSkill(id)`, `skillDownloadUrl(skill)` (Task 2). Produces: the detail/read view showing instructions (`body` markdown), `requestedTools`, source/version/license, the `runnable` state, the bundle `fileManifest` (path/size/executable), and a "Download bundle" link when `hasExecutableBundle`.

- [ ] **Step 1: Clone the prompt detail (read portion)**

Clone the read view of `frontend/src/routes/prompts/[promptId]/+page.svelte` → `skills/[skillId]/+page.svelte`. Load via `getSkill(id)` (mirror the `getPrompt` load + error handling at ~line 79). Render:
- `displayName || name`, `description`.
- `body` via the Markdown component (the same one prompts use).
- `requestedTools` as chips.
- A **runnable/needs-sandbox** indicator from `hasExecutableBundle`.
- Add `data-testid="skill-title"` and `data-testid="skill-detail"`.

- [ ] **Step 2: Artifacts (manifest + download)**

When `hasExecutableBundle` is true, render an "Artifacts" section listing `fileManifest` entries (`path`, human-readable `size`, an "executable" marker for `scripts/` files) and a "Download bundle" anchor: `<a href={skillDownloadUrl(skill)} download>`. Add `data-testid="skill-artifacts"`. A prompt-only skill (no bundle) shows no artifacts section.

- [ ] **Step 3: Typecheck + commit**

```bash
cd frontend && npm run check
git add frontend/src/routes/skills/[skillId]/+page.svelte
git commit -m "feat(skills/spa): skill detail view with artifacts and bundle download"
```

---

### Task 7: Skill authoring — create/edit form, share, delete

**Files:**
- Modify: `frontend/src/routes/skills/[skillId]/+page.svelte` (add the edit form + actions)
- Modify (if a separate new-skill route is cleaner): `frontend/src/routes/skills/new/+page.svelte` OR reuse the `[skillId]` edit form with a `?new` state, matching how prompts handle "create" (check the prompts approach first).

**Interfaces:**
- Consumes: `createSkill`, `updateSkill`, `destroySkill`, `shareSkillToTeam`, `unshareSkillFromTeam` (Task 2). Produces: an authoring form (name, displayName, description, body/instructions, requestedTools as a token input) + Save/Delete/Share-to-team actions, mirroring the prompt edit form.

- [ ] **Step 1: Mirror the prompt edit form**

Read how `prompts/[promptId]/+page.svelte` toggles read vs edit and how "New prompt" creates (the create entry point from `nav-pane`/`new-resource-dialog.svelte`). Replicate for skills: an edit form binding `name`, `displayName`, `description`, `body`, and `requestedTools` (a comma/space token input → string array). Save calls `createSkill` (new) or `updateSkill` (existing); on success refresh `skillsNav` and navigate to the detail.

- [ ] **Step 2: Share + delete actions**

Mirror the prompt share/delete UI: a "Share to team" toggle calling `shareSkillToTeam`/`unshareSkillFromTeam` (gated to workspace context like prompts), and a delete calling `destroySkill` with a confirm, then navigate back to `/skills` and refresh the store. Use `data-testid` on the Save, Delete, and Share controls.

- [ ] **Step 3: New-skill entry**

Wire the "New skill" sidebar action (Task 4) to the create form (a `skills/new` route or the `[skillId]` form in create mode, whichever matches the prompts pattern). Validate `name` against the backend rule (`^[a-z0-9-]{1,64}$`) client-side with a helpful message before submit (the backend also enforces it).

- [ ] **Step 4: Typecheck + commit**

```bash
cd frontend && npm run check
git add frontend/src/routes/skills/
git commit -m "feat(skills/spa): authoring form (create/edit), share, delete"
```

---

### Task 8: Import-bundle upload dialog

**Files:**
- Create: `frontend/src/routes/skills/components/skill-import-dialog.svelte`
- Modify: `frontend/src/lib/components/shell/nav-pane.svelte` (wire the "Import skill" action to open it)

**Interfaces:**
- Consumes: `uploadSkillBundle(file, workspaceId?)` (Task 2), `skillsNav.refresh()`. Produces: a dialog with a file picker (accept `.zip`), an upload action, inline success (navigates to the new skill's detail) and error display.

- [ ] **Step 1: Build the dialog**

Create `skill-import-dialog.svelte`: a shadcn-svelte dialog with a `<input type="file" accept=".zip,application/zip">`, an "Import" button calling `uploadSkillBundle(file, currentWorkspaceId)`, a busy state, and error rendering from the `RpcResult` errors (the import controller returns useful messages like "Import failed: missing_name"). On success, `skillsNav.refresh()` and navigate to `/skills/<data.id>`. Add `data-testid="skill-import-dialog"` and `data-testid="skill-import-submit"`.

- [ ] **Step 2: Wire the trigger**

In `nav-pane.svelte`, the skills-mode "Import skill" action (Task 4) opens this dialog (a `$state` boolean, mirroring how `new-resource-dialog` is toggled).

- [ ] **Step 3: Typecheck + commit**

```bash
cd frontend && npm run check
git add frontend/src/routes/skills/components/skill-import-dialog.svelte frontend/src/lib/components/shell/nav-pane.svelte
git commit -m "feat(skills/spa): zip bundle import dialog"
```

---

### Task 9: In-chat approval card

**Files:**
- Modify: `frontend/src/lib/components/shell/notification-bell.svelte` (render approval_request notifications with an Approve action) OR create `frontend/src/lib/components/chat/approval-card.svelte` and surface it from the notification feed.
- Possibly modify: `frontend/src/lib/stores/notifications.svelte.ts` (expose the metadata + a mark-read call) — only if needed.

**Interfaces:**
- Consumes: the existing `approval_request` notification (`metadata.skill_id`, `metadata.approve_phrase`, `targetConversationId`), `sendUserMessage(conversationId, text, resources)` from `api.ts`, and the notification mark-read path. Produces: an "Approve" button that sends `approve_phrase` to `targetConversationId` and marks the notification read; a "Dismiss"/"Reject" that just marks it read.

- [ ] **Step 1: Read the notification surface**

Read `frontend/src/lib/components/shell/notification-bell.svelte` (how each notification renders; the `approval_request → UserCheck` icon at ~line 35) and `frontend/src/lib/stores/notifications.svelte.ts` (the feed, the channel events `notification.create`/`notification.mark_read`, and the mark-read method). Confirm `sendUserMessage` is exported from `api.ts` (used by `conversation-store.svelte.ts:396`).

- [ ] **Step 2: Render the approval action**

For a notification with `notificationType === 'approval_request'` and `metadata.approve_phrase`, render two buttons inside the bell item: **Approve** and **Dismiss**. Approve:
```typescript
async function approve(n: NotificationEntry) {
  const phrase = n.metadata?.approve_phrase;
  if (phrase && n.targetConversationId) {
    await sendUserMessage(n.targetConversationId, phrase, []);
  }
  await notificationFeed.markRead(n.id);   // use the store's real mark-read method name
  // optionally navigate to `${base}/chat/${n.targetConversationId}` to show the result
}
```
Dismiss just calls `notificationFeed.markRead(n.id)`. Add `data-testid="approval-card"`, `data-testid="approval-approve"`, `data-testid="approval-dismiss"`.

(Confirm the exact `markRead` method name and `sendUserMessage` signature against the real code; the grounding shows `send(text)` on the conversation store and `sendUserMessage(conversationId, text, resources)` in api.ts — use the api function directly since the target conversation may not be the active store.)

- [ ] **Step 3: Typecheck + commit**

```bash
cd frontend && npm run check
git add frontend/src/lib/components/shell/notification-bell.svelte frontend/src/lib/stores/notifications.svelte.ts
git commit -m "feat(skills/spa): in-chat skill approval card (one-click approve)"
```

---

### Task 10: E2E tests (Playwright) + final typecheck

**Files:**
- Create: `frontend/tests/skills.spec.ts`

**Interfaces:**
- Consumes: the `mockRpc` helper and `data-testid` selectors from the other tasks. Produces: Playwright coverage of the skills flow with a mocked backend.

- [ ] **Step 1: Read the reference E2E**

Read `frontend/tests/smoke.spec.ts` — specifically the prompts test (`'prompts mode lists the library and opens a prompt'`) and the `mockRpc` helper (how it mocks `**/rpc/run` actions and the multipart `/rpc/upload`).

- [ ] **Step 2: Write the skills E2E**

Create `frontend/tests/skills.spec.ts` mirroring the prompts test. Cover:
1. **Browse + open:** mock `my_skills` → a list; `get_skill` → a detail; visit `/next/skills`; assert `skills-nav` and `skill-gallery` visible; click a card; assert `skill-title`.
2. **Runnable badge:** a skill with `hasExecutableBundle: true` shows the "needs sandbox/runnable" chip on its card.
3. **Import:** mock `POST /rpc/skills/import` → `{success: true, data: {id, name}}`; open the import dialog (`skill-import-dialog`), set a file on the input, submit (`skill-import-submit`), assert navigation/refresh.
4. **Create:** mock `create_skill` → a detail; use the New skill form; assert success.
5. **Approval card:** seed an `approval_request` notification (mock `unread_notifications` or the channel) with `metadata.approve_phrase`; open the bell; click `approval-approve`; assert it triggers a `send_user_message` (mock that RPC and assert it was called with the phrase).

(Match `smoke.spec.ts`'s exact mocking mechanism. If mocking the Phoenix channel for the notification is impractical, mock the `unread_notifications` RPC load instead and assert the card renders + approve calls `send_user_message`.)

- [ ] **Step 3: Run E2E + full typecheck**

```bash
cd frontend && npm run check
cd frontend && npm run test:e2e -- skills   # confirm the script + filter syntax in package.json
```
Expected: green. Fix any selector/mocks mismatches.

- [ ] **Step 4: Commit**

```bash
git add frontend/tests/skills.spec.ts
git commit -m "test(skills/spa): playwright E2E for browse, import, create, approval"
```

---

## Self-Review

- **Scope coverage (the chosen "+ Approval card & artifacts" tier):** browse (Tasks 4-5), detail (Task 6), authoring form + share + delete (Task 7), zip import (Tasks 2, 8), approval card (Task 9), artifacts view + download (Tasks 1, 6), tests (Tasks 3, 10). All covered.
- **No new backend beyond the download endpoint:** authoring uses the existing `create_skill`/`update_skill`/`destroy_skill`/`share*` RPC; import uses the existing `/rpc/skills/import` controller; approval reuses the existing notification channel + `send_user_message`. Only `GET /skills/:id/download` is new (Task 1).
- **No placeholders:** each frontend task names the exact prompts file to clone and the specific deltas (data source, fields, testids). The backend task ships full controller + test code. The two "confirm the exact name" notes (frontend npm script names; the `WorkbenchMode` type file; the `markRead` method name) name precisely what to verify and where, and give a working default.
- **Type/interface consistency:** `SkillSummary`/`SkillDetail` (Task 2) are consumed by the store (Task 3), gallery (Task 5), and detail (Task 6); `uploadSkillBundle` (Task 2) by the import dialog (Task 8); `skillDownloadUrl` (Task 2) by the detail (Task 6) and backed by the route (Task 1); `sendUserMessage` + `approve_phrase` (Task 9) match the backend's notification metadata.
- **Ordering delivers incrementally:** after Task 5 the user can browse; after Task 8, import; after Task 9, approve. Each task is independently testable (typecheck per task; Vitest for the store; Playwright at the end).
- **Risk flagged:** the approval-card channel mocking in E2E (Task 10 step 2.5) may need to fall back to mocking the `unread_notifications` RPC load if the Phoenix channel cannot be driven in Playwright; the task says so.

## Execution Handoff

Two execution options:
1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks. The backend Task 1 is a clean TDD unit; the frontend tasks are clone-and-adapt against the named prompts files.
2. **Inline Execution** — batch with checkpoints.

Note: the frontend tasks are best verified by `npm run check` (typecheck) per task plus the Playwright E2E at the end, since SPA components are not unit-tested in isolation (only the store is, Task 3). A reviewer should confirm each clone applied the data-layer swap and added the `data-testid` hooks rather than leaving prompt copy behind.
