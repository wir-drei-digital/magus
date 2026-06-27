# User-Managed Skills with Bundled Artifacts: Design

Date: 2026-06-27
Status: Approved design, pending implementation plan

## Summary

Today Magus has hard-coded "skills" (`priv/skills/*.md`): prompt-only markdown that references pre-compiled Jido tools. This design adds **user-managed skills**: shareable resources that bundle their own scripts and CLIs, run in the existing sandbox, and are natively the Anthropic Agent Skills `SKILL.md` standard, with AGENTS.md and Goose as secondary adapters.

The enabling insight: an Anthropic skill is "a bundle of scripts an agent runs in a code-execution environment," and Magus already has that environment. So a bundled skill needs **no new execution tooling**. The bundled CLI is the tool, run via the `exec_command` / `run_code` tools that already exist. What is new is a resource to hold the bundle, an importer that normalizes formats into one internal superset, a step that materializes the bundle into the sandbox, a per-actor discovery merge, and an execution approval gate.

A second capability closes the loop: an agent authoring tool (`create_skill`) that bundles artifacts the agent just built in the sandbox into a new reusable skill. Materialization unpacks an archive into the sandbox; authoring packs the sandbox back into an archive. Same machinery, opposite direction.

## Goals

- Users create, edit, upload, share, and import skills as first-class resources with personal and workspace access scopes.
- Skills can bundle executable artifacts (scripts, CLIs, assets) that run in the sandbox.
- Drop-in import/export of Anthropic Agent Skills (`SKILL.md`, our native format), with a thin adapter layer for adjacent formats (AGENTS.md, Goose).
- An agent can author a skill from work it built in the sandbox, for reuse across conversations.
- Built-in skills keep working unchanged; the two species unify only at the discovery and load layer.

## Non-goals (v1)

- Public cross-user marketplace (publish, browse, copy, moderate). Deferred to a later phase.
- Fully editable in-browser file tree. v1 uses the hybrid model (editable SKILL.md plus an attached artifact archive). The schema keeps a per-file manifest so the editor is an additive Phase 3.
- Static source scanning or trust tiers. v1 relies on sandbox isolation plus a first-run execution approval.
- Dedicated per-skill secret storage. v1 reuses the existing `AgentSecret` `:sandbox_env` injection; a per-user, per-skill `SkillSecret` with per-key scoping is Phase 2.
- Per-skill custom container images.

## Key decisions (from brainstorming)

1. **Superset model.** The internal representation is a superset that native authoring and external formats normalize into. Native authoring and Anthropic import are both v1.
2. **Hybrid storage, file tree latent.** SKILL.md (frontmatter plus body) is stored as structured, in-app-editable fields. The rest of the bundle is an archive in File-storage. A `file_manifest` keeps the per-file representation latent so a future file-tree editor is additive.
3. **Workspace-scoped resource plus import.** A skill is a resource like any other, with personal and workspace access via the existing grant model. Import is via zip upload (v1) and git/URL (Phase 2). No marketplace in v1.
4. **Sandbox plus first-run approval.** The sandbox is the security boundary, the same isolation Magus already trusts for agent-authored code. The first time a bundled skill executes in a conversation, a human approval is required. Secret values are never bundled with a skill: in v1 the sandbox env is populated by the existing `AgentSecret` `:sandbox_env` mechanism, and a skill's optional `required_secrets` is a declarative UX hint.
5. **Sandbox-materialized bundles, reuse existing tools.** Execution rides the existing sandbox and tools rather than compiling typed tools or running an MCP server per skill.

## Standards alignment (2026-06-27 web research)

A cited, adversarially verified web-research pass confirmed the design direction and sharpened the adapter list. Recency caveat: this space moves fast and much of the governance/adoption detail is post the assistant's knowledge cutoff, so re-verify field-level details against the live spec (agentskills.io) before implementation. The structural facts below match the format's original launch and are treated as stable.

- **`SKILL.md` (Anthropic Agent Skills) is the convergent cross-vendor format** for portable skill bundles: a directory with a `SKILL.md` (YAML frontmatter + Markdown body) plus optional `scripts/`, `references/`, `assets/`, executed via progressive disclosure and bash-run bundled scripts. It is structurally identical to our internal model and is adopted across many harnesses (Claude Code, OpenAI Codex, Gemini CLI, Cursor, GitHub Copilot, opencode/sst, Goose, and others).
- **Decision: our native format IS `SKILL.md`, extended as a strict superset.** Required frontmatter: `name`, `description`. Optional standard fields: `license`, `compatibility`, `metadata`, `allowed-tools` (experimental). Our `requested_tools` serializes as `allowed-tools`; our extras (`required_secrets`, `runtime_hints`, `version`) live under the arbitrary `metadata` map (exactly where the standard itself places `version`). Result: every Magus skill is a valid Agent Skill, and every Agent Skill imports losslessly.
- **Codex needs no separate adapter:** OpenAI Codex consumes the same Agent Skills standard, so importing a Codex skill is just parsing `SKILL.md`. The previously planned `:codex` adapter is dropped.
- **MCP is an adjacent layer, not a bundle format:** it is the typed-tool transport a skill may call into, already integrated at the Magus tool layer. No MCP skill adapter.
- **AGENTS.md is prompt-only guidance** (no scripts, no bundle). An AGENTS.md import maps to a prompt-only skill (populates `body`, never `scripts/`).
- **Reprioritized adapters:** (a) `SKILL.md` = native import/export, highest interop; (b) AGENTS.md = import-only, prompt-only; (c) Goose recipes = optional later (prefer exporting `SKILL.md` to Goose, which supports the standard).
- **Governance asymmetry (recorded risk):** MCP and AGENTS.md are under the Linux Foundation's Agentic AI Foundation; `SKILL.md` is Anthropic-origin-open but not yet under neutral-foundation governance. Adoption momentum still makes it the right target; track agentskills.io.
- **Security reinforcement:** the ecosystem already shows skill marketplaces without mandatory security review, which validates our sandbox + first-run-approval + opt-in-secrets posture for imported third-party code.

## Architecture overview

Two species, unified at discovery and load:

- **Built-in skills** (`priv/skills/*.md`): prompt-only, global, reference compiled tools. Unchanged.
- **User skills** (DB-backed `Magus.Skills.Skill`): hybrid bundles, access-scoped, may carry executable artifacts and declare secrets.

The agent sees one merged skill list. `load_skill` dispatches by source. Built-in skills behave exactly as today. User skills additionally materialize their bundle into the sandbox and pass through the approval gate before any bundled code runs.

Reused subsystems:

- Sandbox: `Magus.Sandbox.Orchestrator` (one sandbox per conversation, auto-created, persistent `/workspace`, egress restricted to package registries, destroyed on conversation delete).
- Tools: existing sandbox tools (`ExecCommand`, `RunCode`, `InstallPackages`, `StartService`, file tools) and the existing `@skill_tool_mapping` in `Magus.Agents.Tools.ToolBuilder`.
- Approval: `RequestApproval` tool plus `InboxEventPlugin` approval matching.
- Storage: `Magus.Files.Storage` (local/S3 backend, stamped at write).
- Secrets: `Magus.Agents.AgentSecret` (`:sandbox_env` env-var injection), reused directly in v1.
- Sharing: `Magus.Workspaces.Policies.workspace_scoped_policies/1`, `ResourceAccess`, `share_to_team`/`unshare_from_team`.
- SPA: SvelteKit mode strip plus AshTypescript RPC over `/rpc/run`, multipart upload over `/rpc/upload`.

## Data model

New domain `Magus.Skills` with a `Skill` resource. The existing `Magus.Agents.Skills.Registry` becomes the discovery/merge layer that unifies built-in registry skills with DB-backed user skills for a given actor.

### `Magus.Skills.Skill`

- Identity/display: `name` (the `SKILL.md` name: lowercase, numbers, hyphens, max 64 chars, no reserved words, unique per owner scope), `display_name`, `description` (drives discovery, max 1024 chars), `license`, `compatibility`, `icon`, `color`. `version` is not top-level; it lives under `metadata` per the standard.
- Instructions: `body` (the SKILL.md markdown body, progressive-disclosure layer 2).
- Capability declarations (serialized as a strict `SKILL.md` superset):
  - `requested_tools` (`{:array, :string}`): existing Magus tools the skill wants, resolved through `@skill_tool_mapping`. Serializes to/from the standard `allowed-tools` frontmatter field (experimental in the spec); unknown names retained but inert.
  - `metadata` (`:map`): the standard arbitrary key-value map. Carries `version` plus the Magus-specific extras below under a namespaced key, so a Magus skill stays a valid Agent Skill and any Agent Skill imports losslessly.
  - `required_secrets` (`{:array, :map}`): `[%{key, description}]`, opt-in, never auto-injected. Serialized under `metadata`.
  - `runtime_hints` (`:map`): optional `%{packages: [...], image: ...}`. Serialized under `metadata`.
- Bundle: `bundle_file_id` (FK to `Magus.Files.File`, nullable, nil means prompt-only), `file_manifest` (`{:array, :map}` of `%{path, size, sha256, executable?}`), `has_executable_bundle` (boolean, gates the approval path). The bundle preserves the standard `SKILL.md` layout (`scripts/`, `references/`, `assets/`), so imported relative paths resolve unchanged after materialization.
- Provenance: `source_format` (`:skill_md` native/Anthropic/Codex, `:agents_md`, `:goose`, `:other`), `source_url` (nullable).
- Scoping: `user_id` (owner), `workspace_id` (nullable), `deleted_at` (soft delete).

Nullable attributes follow the schema rule from CLAUDE.md (use `{:or, [type, nil]}`, not a bare type with `default: nil`). AshPaperTrail versions (like Brain pages) are a Phase 2 add for import-v1-vs-edited-v2 history.

### Secrets (v1 reuses `AgentSecret`)

Secrets are sandbox environment variables, the same model Anthropic skills use (the `SKILL.md` standard has no secrets field). Magus already injects them via `Magus.Agents.AgentSecret` with scope `:sandbox_env`. v1 reuses that directly, so a skill running under a custom agent gets that agent's env secrets. A skill's `required_secrets` (carried under `metadata`) is an optional declarative hint only: it drives the UI prompt and the agent's "missing key" message; it stores no value, and an imported skill that omits it still runs. A dedicated per-user, per-skill `SkillSecret` (inject only declared keys; cover skills used outside a custom agent) is deferred to Phase 2.

### Conversation tracking

Per conversation we track the set of materialized and approved skills. Exact home (a small array field on `Conversation` vs a `ConversationSkill` join row) is resolved in the plan. Existing `conversation.skill_context` and `conversation.skill_tools` are reused for the body and requested tools, so no churn there.

## Discovery and progressive disclosure

The "## Available Skills" system-prompt section is composed per-conversation from:

- built-in registry skills (global), plus
- user skills the actor can access (personal, workspace, granted), plus
- the agent's pre-loaded skills (`CustomAgent.pre_loaded_skills`, extended to reference user-skill ids as well as registry names).

Only name and description are exposed at this layer; the body stays out until load. This is the one notable change from today's global, cached section. Built-in skills remain in the stable (cached) prefix. The user-skill list is per-conversation but stable across turns unless the skill set changes, so cache impact is bounded. The exact stable-prefix split is measured in the plan.

## Runtime flow

1. **Discovery.** Agent sees the skill (name plus description) in the merged list.
2. **Load.** Agent calls `load_skill(name)`. The dispatcher branches:
   - Built-in: unchanged (body to `skill_context`, tools to `skill_tools`).
   - User skill: persist `body` to `skill_context`, resolve `requested_tools` to `skill_tools` (existing path, including mid-turn `__new_tools__` registration in the ReAct runner). If `has_executable_bundle`, proceed to materialize.
3. **Materialize.** Ensure the conversation sandbox exists (orchestrator auto-creates), then unpack the archive into `/workspace/.skills/<name>/`, idempotent via a marker so suspend/resume and re-loads do not re-unpack. Secret values come from the existing `AgentSecret` `:sandbox_env` injection (v1); the skill's `required_secrets` is a declarative hint, not a value store. Optional `runtime_hints.packages` install via the existing `install_packages`.
4. **Approve (first-run gate).** The first time a bundled skill is activated in a conversation, before its code can run, the agent raises an approval through `RequestApproval`, matched by `InboxEventPlugin`. The prompt names the skill and surfaces declared secrets and packages. The decision is remembered per conversation. A self-authored skill is flagged "authored by you" to reduce friction. Per-user "always trust this skill" is Phase 2. Built-in and prompt-only skills skip the gate.
5. **Execute.** The agent runs the bundled CLIs via existing `exec_command` / `run_code` / `start_service`. The SKILL.md body tells it how (for example `python .skills/<name>/foo.py`). Files persist in `/workspace` for the conversation. No new execution tool is introduced.

## Agent authoring tool: `create_skill`

A new authoring tool (not an execution tool, so it does not break the no-new-execution-tools property).

- **Params:** `name`, `description`, `body` (the SKILL.md the agent writes), `include_paths` (sandbox files/dirs to bundle; empty means a prompt-only skill), and optional `requested_tools`, `required_secrets`, `runtime_hints`, `workspace_id`. Nullable params use `{:or, [type, nil]}`.
- **Run:** validate context (`user_id`, `conversation_id`), read `include_paths` from the conversation sandbox (existing orchestrator read/download), safe-pack into an archive, store via File-storage, compute `file_manifest`, create a `Skill` row owned by the acting user (workspace-shared if requested). Returns the new skill id and name; it is discoverable on the next turn.
- **Trust:** creating is low-risk (it persists files from the user's own sandbox, scoped to the user), so no approval to author. The first-run execution gate still applies when the skill is later loaded.
- **The loop:** "Build me a CLI that does X" leads to the agent writing and testing it in the sandbox, then calling `create_skill`. A later conversation loads that skill and runs the CLI instead of rebuilding it. Skills become durable memory for agent-built tooling.

## Import and format adapters

v1 sources: zip upload and native authoring. git/URL is Phase 2.

Pipeline (a dedicated multipart `/rpc/skills/import` controller, since it unpacks and validates rather than storing a single blob):

1. Multipart upload of the zip.
2. **Safe unpack**, reusing the boundary-safe path-traversal guard from `Magus.Files.Storage.Local` (commit `mw8p`): reject absolute paths, `..` escapes, and symlinks; enforce max file count, max total size, max single-file size.
3. Locate `SKILL.md` (repo root or a single top-level dir), parse YAML frontmatter plus body with the same parser the Registry uses.
4. **Normalize via adapter** (detect format, map into the superset).
5. Persist: the `Skill` row plus the remaining bundle files as an archive in File-storage (`bundle_file_id`) plus a computed `file_manifest`.

Formats (our native format is `SKILL.md` itself, so most "import" is just parsing):

- **`SKILL.md` (Anthropic Agent Skills) = native:** round-trip import/export, no lossy mapping. `name`/`description`/`license`/`compatibility` are top-level; `allowed-tools` maps to `requested_tools` (best-effort against `@skill_tool_mapping`, unknown names retained but inert); `metadata` carries `version` and the Magus extras. OpenAI Codex consumes this same standard, so a Codex skill needs no separate adapter.
- **AGENTS.md = import-only, prompt-only:** populates a skill's `body`/instructions, never `scripts/` (AGENTS.md bundles no executables).
- **Goose recipes = optional, later:** a Goose-specific YAML/JSON manifest. Prefer exporting `SKILL.md` to Goose (which supports the standard) over emitting recipes; only add a recipe adapter if Goose-native features are needed.
- **MCP is not a bundle format:** it is the orthogonal typed-tool transport a skill may call, already integrated at the Magus tool layer. No MCP skill adapter.

The adapter boundary keeps new formats additive: each is one normalizer into the superset, never a core change. Detection keys off the frontmatter shape with an explicit `source_format` override allowed. **Export** (repack `Skill` to a `SKILL.md` bundle from structured fields) is cheap and gives portability to every skills-compatible harness plus a future marketplace; slotted as v1-if-cheap, else Phase 2.

## Security model

- **Boundary:** the sandbox is the same isolation Magus already trusts for agent-authored code (egress restricted to package registries, one sandbox per conversation, auto-suspend, destroyed on delete). Running a skill's CLIs is the same execution class, now with provenance attached.
- **First-run approval:** see runtime flow step 4. Reuses `RequestApproval` plus `InboxEventPlugin`.
- **Secrets:** sandbox env vars, never bundled with the skill. v1 reuses the existing `AgentSecret` `:sandbox_env` injection for values; a skill's optional `required_secrets` is a declarative UX hint (under `metadata`). Missing keys do not block load; the agent is told which are unset. Per-skill `SkillSecret` with per-key scoping is Phase 2.

## Sharing and access control

Register `:skill` in `ResourceAccess`'s `@resource_types`, then on the resource:

- `workspace_scoped_policies(resource_type: :skill)`.
- `share_to_team` / `unshare_from_team` actions via `GrantWorkspaceAccess` / `RevokeWorkspaceAccess`.
- `DestroyResourceGrants` on destroy.
- `is_shared_to_workspace` calculation for the UI.

This is identical to agents, prompts, and brains. Personal is the default (nil workspace). Workspace admins are implicitly owners.

## UI layer (SPA)

A new `skills` mode next to `prompts`, reusing the library patterns:

- **Nav:** add a `skills` entry to the mode strip (`frontend/src/lib/components/shell/mode-strip.svelte`) and `/skills` to `MODE_HOME`. The `WorkbenchMode` union and the backend `TabSession.mode` enum both gain `skills`.
- **Routes** mirroring prompts: `/skills` master/detail layout, a `skill-gallery` list with scope/tag/search filters, a `skills-nav` sidebar, and `/skills/[skillId]` detail.
- **Detail/editor** for native authoring: name, description, body (markdown/code editor), declared `requested_tools`, declared `required_secrets` (key plus description; values entered separately and stored encrypted), and an artifacts panel listing `file_manifest` entries with upload/replace/remove. Share-to-workspace is the same dropdown toggle prompts use.
- **Two creation entry points:** "New skill" (native authoring, optional artifact zip) and "Import skill" (Anthropic zip).
- **Backend exposure:** declare RPC actions on the `Skills` domain (`my_skills`, `workspace_skills`, `get_skill`, `create`, `update`, `destroy`, `share_to_team`, `unshare_from_team`, add/remove secret) and run `mix ash_typescript.codegen`. Bundle/artifact upload and zip import go through the dedicated multipart import/upload controller.

## Error handling and capability gating

- **No sandbox provider:** bundled skills still list but are marked "requires code execution (unavailable here)"; loading one returns a clear message. Prompt-only user skills work regardless. Mirrors the existing `Sandbox.Provider.configured?/0` gating in `tool_builder.ex`.
- **Import failures** are specific and typed (missing `SKILL.md`, invalid frontmatter, unsafe path, oversize, too many files) so the SPA can show them.
- **Materialization failure** (sandbox died mid-conversation): surfaced to the agent, retried on next load, idempotent marker prevents partial double-unpack.
- **Unknown `requested_tools`:** ignored with a warning, exactly as `resolve_skill_tools/1` does today.
- **Kill-switch:** a `Magus.Skills.enabled?` flag (like `SuperBrain.enabled?`) lets an instance disable the whole feature.

## Phasing

- **Phase 1 (core runtime plus manual UI):** `Skill` resource plus `Magus.Skills` domain plus policies; secrets via the existing `AgentSecret` `:sandbox_env` reuse (no new resource); discovery merge (built-in plus user); `load_skill` dispatch; sandbox materialization; first-run approval; capability gating plus kill-switch; RPC actions; SPA `skills` mode (list/detail/share); import (zip plus Anthropic adapter) and native authoring with artifact upload.
- **Phase 2 (payoff plus ergonomics):** the `create_skill` agent authoring tool; git/URL import; `SKILL.md` export/round-trip; AGENTS.md import (prompt-only); dedicated `SkillSecret` (per-user, per-skill, per-key scoping, secrets outside a custom agent); per-user "trust this skill"; `runtime_hints` package preinstall; AshPaperTrail versions. The `create_skill` tool may be pulled into late Phase 1 once the resource and storage exist (decide during planning).
- **Phase 3 (deferred):** fully editable in-browser file tree; Goose recipe adapter; public marketplace (publish, copy, discovery, like the public Prompt library).

## Testing

- **Unit:** adapter normalization (real Anthropic `SKILL.md` fixture into the superset), safe-unpack/path-traversal rejection, manifest extraction, capability gating, access-scope policies, `load_skill` dispatch (built-in vs user), approval state, secret-injection scoping, and `create_skill` (sandbox files into archive into `Skill` row).
- **Live E2E (sandbox-tagged, via `bin/test-e2e-live --include sandbox`):** import an Anthropic skill, load it in a conversation, materialize, run a bundled script through `exec_command`, assert output. Then the full loop: agent builds a CLI, calls `create_skill`, a fresh conversation loads it and runs it.
- **Policy and frontend tests** stay structural (data-* hooks plus counts, no brittle label/copy assertions).

## Open questions (resolved in the plan, none blocking)

- Exact home of the approved/materialized skill set per conversation (array field vs join row).
- Cache impact of per-conversation skills-section composition (keep built-in skills in the stable prefix; measure the user-skill delta).
- `SkillSecret` scoping when it lands in Phase 2: per-user vs agent-scoped override vs workspace-shared team values.

## Affected and new modules (indicative)

New:

- `lib/magus/skills/skills.ex` (domain), `lib/magus/skills/skill.ex` (`lib/magus/skills/skill_secret.ex` is Phase 2).
- `lib/magus/skills/import/` (safe unpack, `SKILL.md` parse and normalizer; AGENTS.md and Goose adapters in later phases).
- `lib/magus/skills/materializer.ex` (archive to sandbox, idempotent marker).
- `lib/magus/agents/tools/skills/create_skill.ex` (authoring tool, Phase 2 or late Phase 1).
- `lib/magus_web/rpc/skills_controller.ex` (multipart import/upload).
- `frontend/src/routes/skills/...`, `frontend/src/lib/components/shell/skills-nav.svelte`, `frontend/src/lib/stores/skills-nav.svelte.ts`, `frontend/src/lib/ash/api.ts` additions.

Changed:

- `lib/magus/agents/skills/registry.ex` (discovery/merge layer over built-in plus user skills).
- `lib/magus/agents/tools/skills/load_skill.ex` (dispatch built-in vs user, trigger materialize and approval).
- `lib/magus/agents/tools/tool_builder.ex` (per-actor user-skill resolution, capability gating already present for sandbox tools).
- `lib/magus/agents/context/system_prompts.ex` (per-conversation skills section composition).
- `lib/magus/workspaces/resource_access.ex` (`:skill` resource type).
- `lib/magus/agents/custom_agent.ex` (`pre_loaded_skills` resolves user-skill ids).
- `lib/magus/chat/conversation.ex` (approved/materialized skill tracking).
- Domain RPC config for AshTypescript plus `mix ash_typescript.codegen`.
- `TabSession.mode` enum gains `skills`.
