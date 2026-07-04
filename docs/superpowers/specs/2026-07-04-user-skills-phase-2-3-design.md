# User Skills Phase 2 + 3: Slash Triggers, Trust, Secrets, Exchange, Surfaces

Date: 2026-07-04
Status: approved (brainstormed with the user; decisions recorded inline)
Predecessor: `2026-06-27-user-managed-skills-design.md` (Phase 1, shipped to main via PR #5 and verified: live sandbox E2E vs Daytona 2/2 green; full in-browser flow verified)

## Summary

Phase 1 shipped the full skills slice: the `Magus.Skills` domain, zip import, SKILL.md parsing, workspace-scoped sharing, sandbox materialization with first-run approval, the `create_skill` authoring tool, and the SPA Library UI. This spec covers the next slice, in one combined document (user decision) executed as three plan documents:

- **Slash-command skill triggers**: `/my-skill do X` deterministically loads a skill into the turn.
- **Approval evolution**: a `ConversationSkillApproval` join row (replacing the `approved_skill_ids` array), content-hash binding, slash-as-approval, and per-user "always trust".
- **Secrets**: a per-user `SandboxSecret` vault with declared-key injection.
- **Exchange**: SKILL.md export generated from structured fields (fixing the stale-download gap), URL import (no git client), AGENTS.md import, `runtime_hints` package preinstall, import hardening.
- **Surfaces (Phase 3)**: in-browser file-tree editor and a public marketplace on the prompt-library pattern.

## Challenged assumptions (changes vs the 2026-06-27 spec)

Each of these was an explicit decision in this brainstorm; the old spec's position is noted.

1. **Approval storage**: Phase 1 chose a `{:array, :uuid}` field (`conversation.approved_skill_ids`). That cannot carry who approved (the recorded multiplayer-attribution gap), what content was approved, or how. **Replaced by a join row with a data migration.**
2. **Slash invocation counts as approval.** The first-run gate exists because the *agent* autonomously loads third-party code; a user-typed `/skill` invocation is itself the human-in-the-loop act. Requiring a second card click after an explicit invocation is ceremony without added safety (the sandbox remains the boundary).
3. **Secrets are per-user, not per-skill.** The old spec deferred a per-user-per-skill `SkillSecret`. Per-skill values duplicate shared keys (three skills needing `DEEPL_API_KEY` = three copies). **A user-level vault with declared-key injection** stores each key once; a skill receives only the keys it declares, and the approval card discloses them.
4. **"git/URL import" needs no git.** Forges serve repo archives over HTTPS (codeload). One URL-fetch mechanism with SSRF/size guards covers the use case; a git client adds a dependency and attack surface for zero gain.
5. **AshPaperTrail versioning is cut** (was Phase 2). Nothing consumes version history yet; the frontmatter `version` string suffices. Revisit if the marketplace needs published-version pinning.
6. **The Goose recipe adapter is cut** (was Phase 3). Goose consumes the SKILL.md standard; export covers it.
7. **Download must serve a generated export, not the original blob.** Phase 1's download serves the imported zip, which goes stale after any in-app edit, and authored prompt-only skills have no bundle at all. Export-from-structured-fields becomes the single bundle source (and the marketplace copy mechanism).

## Goals

- A user can trigger any visible runnable skill with `/name args` from the composer; the skill's instructions are guaranteed to be in context for that turn.
- Approvals record who, what content (bundle sha), and how (slash / card / trust); users can opt into skipping the card per skill.
- A user stores sandbox secrets once and skills receive only their declared keys, visibly.
- Skills round-trip: import from zip, URL, or AGENTS.md; export a spec-valid SKILL.md bundle reflecting current (edited) state.
- Bundled skills can declare packages to preinstall at materialization.
- Phase 3: edit bundle files in the browser; publish/browse/copy skills publicly.

## Non-goals

- Ratings, comments, moderation queues, or paid distribution in the marketplace (admin unpublish + report-to-admin only).
- Resource-level version history (AshPaperTrail) — cut, see above.
- Goose recipe emission — cut, see above.
- Per-skill container images, static analysis / scanning of bundle code.
- Classic-workbench UI changes (SPA only, per project direction).

---

## 1. Slash-command skill triggers

### Resolution

`Magus.Agents.SlashCommands.get/2` gains a skills source. Resolution order on name collision:

1. Agent commands (existing, defined on the active `CustomAgent`)
2. **User-visible runnable skills** — from `Magus.Skills.Discovery.list_for_actor/1`, matched on `name` (kebab-case, same charset as command names); only `runnable` skills participate
3. Global commands (existing `@global_commands`)

The skills lookup needs an actor and conversation, so the entry point becomes `SlashCommands.resolve(text, agent_commands, actor: user, conversation: conv)` (the existing `parse/2` remains for the static sources; `Preflight` calls the new resolve). Discovery is already per-actor authorized; no new policy surface.

### Semantics (deterministic pre-load — user decision)

When `/name` resolves to a skill, `Preflight`:

1. Calls **`Magus.Skills.Loader.load(skill_ref, conversation, actor_user_id, source: :slash_command)`** — a new module extracted from the current `LoadSkill` tool body so the tool and preflight share one code path. `Loader.load/4` handles the same cond as today: prompt-only → inject; bundled + no sandbox → unavailable message; bundled → ensure approval, materialize, inject.
2. Because the invocation is user-typed, the approval is recorded **before** materialization with `source: :slash_command` (see §2) — no card, no pending state, for any skill the user can see.
3. Injects the skill body into `conversation.skill_context` / `skill_tools` exactly as `load_skill` does. The remaining text after the command passes through as the user's message (existing `parse/2` behavior).
4. Materialization is synchronous in preflight. The sandbox cold-start cost is inherent to running the skill (the agent's first exec would pay it anyway); a progress signal (`tool.progress`-style on `agents:{conversation_id}`) keeps the UI honest during provisioning.
5. On load failure (storage error, sandbox down), preflight falls back to passing the raw text through with a system note prepended so the agent can explain — a failed skill load must not eat the user's message.

`LoadSkill.run/2` becomes a thin wrapper over `Loader` (agent-initiated loads keep the approval gate: `source: :approval_card` path).

### SPA

`frontend/src/lib/chat/catalog.ts` merges the user's runnable skills into the slash-command entries (new `skillCommands` fetch via existing skills RPC; cached per workspace like agent entries, invalidated by the skills-nav refresh hook). Entries carry the sandbox badge for bundled skills and the skill description as subtitle. Composer autocomplete needs no structural change — it renders whatever the catalog returns.

## 2. Approval evolution

### `ConversationSkillApproval` (new resource, replaces the array)

```
conversation_id  uuid  (FK, delete: cascade)
skill_id         uuid  (FK, delete: cascade)
bundle_sha       string  (sha256 hex of the approved bundle; nil for prompt-only skills)
approved_by_id   uuid  (FK users, delete: nilify)
source           atom  :slash_command | :approval_card | :trusted
identity: unique (conversation_id, skill_id)
```

- Approval check: a skill is approved in a conversation when a row exists **and** (`bundle_sha` matches the skill's current `bundle_sha` or the skill is prompt-only). A sha mismatch behaves exactly like "not approved" (re-gate) — this closes the hole where a workspace member edits a shared bundle after a colleague approved it.
- **Data migration**: create rows from existing `approved_skill_ids` arrays (`bundle_sha` = the skill's current sha, `approved_by_id` = conversation owner, `source: :approval_card`), then drop the array attribute and its `record_skill_approval` array-append path. `Magus.Chat.record_skill_approval` keeps its name/callers but writes the join row (it is called from `InboxEventPlugin`'s matcher and from tests).
- `Skill` gains an explicit **`bundle_sha`** attribute (backfilled by parsing the content-addressed `bundle_path`; import/export/editor set it directly going forward).

### Per-user trust: `SkillTrust` (new resource)

```
user_id           uuid (FK, cascade)
skill_id          uuid (FK, cascade)
bundle_sha_at_grant string (nil for prompt-only)
identity: unique (user_id, skill_id)
```

- When the acting user trusts a skill, agent-initiated loads skip the card and record the conversation approval with `source: :trusted`.
- If the skill's `bundle_sha` differs from `bundle_sha_at_grant`, the trust is stale: the card shows once ("skill changed since you trusted it"), and approving refreshes the grant.
- Grant points: an "Always allow this skill" checkbox on the approval card, and a toggle on the skill detail page. Revoke from the detail page.

### Approval card

The card (notification bell, `approval_request` type) additionally shows: the declared secret keys the skill will receive (§3) and the trust checkbox. The `approve_phrase` chat-message mechanism stays as the transport (it works and is multiplayer-visible); the recorded row now attributes the actual approver (the message author), fixing the multiplayer-attribution carry-over.

## 3. Secrets: per-user vault, declared-key injection

### `SandboxSecret` (new resource, in `Magus.Skills` domain)

```
user_id  uuid (FK, cascade)
key      string (env-var charset, uppercased convention)
value    Magus.Agents.AgentSecret.EncryptedString (reuse the existing Cloak AES-256-GCM Ash type)
description string, optional
identity: unique (user_id, key)
```

Owner-only policies (no workspace sharing of secret values in this phase). Managed on a new Settings page ("Sandbox secrets": list keys, add, rotate, delete — values write-only in the UI, never read back in plaintext).

### Injection

At materialization, after file writes and before the marker, the Materializer resolves the skill's `required_secrets` (already `{:array, :map}` with `%{"key" => ...}` entries) against the **invoking user's** vault and appends `export KEY=value` lines for the found keys to `/workspace/.env` (the existing convention scripts source). Only declared keys are ever injected. Missing keys do not block the load; the injected/missing key lists are included in the load result so the agent can tell the user what is unset. The approval card lists the declared keys up front (consent disclosure).

Existing `AgentSecret` `:sandbox_env` injection for agent-bound conversations is untouched; when both apply, agent secrets and skill-declared user secrets are merged (agent values win on key conflict, since the agent owner curated them for that context).

## 4. Import expansion

- **URL import (no git client).** The import dialog accepts a URL. Recognized forge repo URLs (github.com, gitlab.com — path-based detection) are rewritten to their HTTPS zip-archive endpoints (e.g. codeload, `/-/archive/`); any other URL must serve a zip (or a bare `.md`, below) directly. Server-side fetch via Req with: response size cap (same limit as upload), content-type check, redirect limit, timeout, and a private-IP / link-local SSRF guard following the existing web-fetch tool's pattern. The fetched bytes then enter the exact same `Import.import_bundle/2` pipeline as an upload; `source_url` is recorded on the skill.
- **AGENTS.md import (prompt-only).** The dialog accepts a bare `.md` file or a URL to one → a prompt-only skill: filename/heading-derived `name` (user-editable before save), full text as `body`, `source_format: :agents_md`, never any scripts.
- **Hardening (carry-overs from Phase 1 review + browser testing):**
  - `Unpack` skips zip **directory entries** (CLI-made zips include them; they currently surface as 0-byte `scripts/` rows with an `exec` badge in the artifacts table and pollute `file_manifest`).
  - **Orphaned-blob cleanup**: if the Skill row create fails after `Storage.store`, delete the stored blob (content-addressed paths make this an idempotent best-effort delete guarded by "no other skill references this sha").
  - The missing `Unpack` limit tests (max file count / total size / single-file size atoms) get written.

## 5. Export: generated bundles, round-trip

New **`Magus.Skills.Export`**: builds a zip from structured fields — `SKILL.md` composed of spec-valid frontmatter (`name`, `description`, `license`, `compatibility`, `allowed-tools` as a space-separated string from `requested_tools`, and `metadata` with Magus extras JSON-encoded under the single `x-magus` string key) plus `body`, then the bundle's artifact files (from the stored archive, filtered through `file_manifest`).

- `GET /skills/:id/download` switches to serving the generated export (filename `<name>.zip`). Works for prompt-only skills too (a one-file SKILL.md bundle). The original imported blob remains in storage as provenance but is no longer what users download.
- Round-trip property (tested): export → import produces an equivalent skill (same parsed fields, same manifest modulo ordering).
- Export is the copy mechanism for the marketplace (§7) and the write-back path for the editor (§6).

## 6. runtime_hints preinstall

`runtime_hints` (existing `:map` attribute) supports `{"pip": ["pkg", ...], "npm": [...]}`. After file writes and secret injection, before the idempotent marker, the Materializer runs the corresponding installs through the existing sandbox exec path with: allowlisted package managers only (`pip`, `npm` initially), package-name charset validation (no shell metacharacters; names are passed as argv, never interpolated into a shell string), and a bounded timeout. Install failure does not block the load; the failure list rides the load result for the agent to relay. The marker records that preinstall ran so re-loads skip it.

## 7. File-tree editor (Phase 3)

The skill detail view's artifacts table becomes a file tree (from `file_manifest`). Text files under a size cap (256 KB) open in an in-browser editor (CodeMirror, already shipped with the SPA); binaries and oversized files are download-only. Saving a file:

1. RPC sends the file path + new content.
2. Backend unpacks the current bundle (safe-unpack path), replaces the file, re-packs via `Export`, stores the new archive (new content-addressed path), updates `bundle_path`, `bundle_sha`, `bundle_byte_size`, `file_manifest`.
3. The sha change automatically re-gates conversation approvals and stales trust grants (§2) — editing a bundle is exactly "new content needs new consent".

`SKILL.md` itself is shown **read-only** in the tree with an "Edit as form" link to the existing structured editor — the structured fields stay the single write path for manifest content, so the fields and the file can never diverge. (Parse-round-trip editing of SKILL.md in the tree is explicitly out of scope.)

## 8. Marketplace (Phase 3)

Prompt-library pattern, OSS (not cloud-gated):

- `Skill.is_public` boolean + `publish`/`unpublish` actions (owner-only; publishing requires `name`, `description`, non-empty `body`), `public_skills` read with `authorize_if expr(is_public == true)` policy, mirroring `Library.Prompt`.
- Public gallery route in the SPA Library mode (browse, search by name/description, sandbox badge prominent).
- **Copy-to-my-library**: server-side Export of the public skill → Import as the acting user (fully-owned snapshot, no live linkage to the source; `source_url` records the origin skill id). The copy arrives un-approved and un-trusted like any import.
- Safety: sandbox + approval + declared-secrets disclosure carry the security load; admin unpublish via existing admin surface; no ratings/moderation this phase.

## 9. Performance and hardening carry-overs

- **Per-turn discovery cache**: the system-prompt skills section currently runs an authorized Skills read every turn. Cache the per-actor discovery result for the duration of one turn (turn-context/process cache), keeping built-in skills in the stable prompt prefix for cache friendliness.
- **`load_skill` idempotency**: replace the substring check on `skill_context` with a sentinel marker (comment line with the skill ref + sha) so re-loads and content overlaps cannot false-positive.
- **nil-actor logging**: autonomy-path loads (no user actor) get a distinct log line for auditability.

## Security model (delta)

- The sandbox remains the execution boundary. What changes is consent granularity: approvals bind to bundle content (sha), invocation source is recorded, and explicit user invocation (slash) is recognized as consent.
- Secrets: values encrypted at rest (existing Cloak type), write-only UI, declared-key-only injection, disclosure on the approval card. URL import adds an SSRF guard. Preinstall passes package names as argv with charset validation.
- New attack surface acknowledged: a malicious public skill can declare popular secret keys hoping the user has them. Mitigations: keys are disclosed on the approval card before any injection, injection only happens for keys the user actually stored, and copies from the marketplace arrive un-trusted.

## Data model summary

| Change | Kind |
|---|---|
| `ConversationSkillApproval` | new resource + data migration from `approved_skill_ids`, then drop the array |
| `SkillTrust` | new resource |
| `SandboxSecret` | new resource (Cloak-encrypted value) |
| `Skill.bundle_sha` | new attribute, backfilled from `bundle_path` |
| `Skill.is_public` | new attribute (Phase 3 / marketplace) |

All new resources live in the existing `Magus.Skills` domain (no new domain, so the dual `:ash_domains` / `Magus.Domains.@core_domains` registration gotcha does not apply) and use the standard policy patterns. `SandboxSecret` is deliberately owner-only with no `workspace_id` — it is a personal vault, not a workspace-scoped resource.

## UI summary (SPA only)

- Composer slash menu lists skills (sandbox badge, description subtitle).
- Approval card: declared secret keys + "Always allow" trust checkbox.
- Skill detail: trust toggle, publish/unpublish (Phase 3), file tree editor (Phase 3), download serves generated export.
- Settings: "Sandbox secrets" page (list/add/rotate/delete, write-only values).
- Library: public gallery tab (Phase 3).

## Testing

- **Unit**: SlashCommands resolution order + skills source; Loader extraction parity (tool and preflight produce identical injection); approval sha-binding + migration correctness; trust staleness; vault injection scoping (declared-only, agent-secret merge precedence); URL rewrite + SSRF guard; AGENTS.md normalization; export round-trip property; dir-entry skipping; orphan cleanup; preinstall argv validation; discovery cache (one read per turn).
- **Policy**: SandboxSecret owner-only; public_skills read; copy-to-library actor scoping.
- **Live E2E** (`bin/test-e2e-live <file> --include sandbox`): slash-trigger a bundled skill end-to-end (message with `/skill` → approval row with `source: :slash_command` → materialized → script runs); secrets injection asserted inside the sandbox (`source /workspace/.env; echo $KEY`); preinstall smoke.
- **Frontend**: structural (data-testid + counts) — slash menu contains skill entries, approval card shows keys + checkbox, settings page CRUD, editor save round-trip, gallery copy.

## Phasing: one spec, three plan documents

- **Plan 2A — runtime**: Loader extraction, slash triggers (backend + SPA catalog), `ConversationSkillApproval` + migration + attribution, `SkillTrust`, `SandboxSecret` + injection + settings UI, approval-card additions.
- **Plan 2B — exchange**: Export + download switch, URL import + SSRF guard, AGENTS.md import, unpack dir-entry fix + orphan cleanup + limit tests, `runtime_hints` preinstall, §9 carry-overs.
- **Plan 3 — surfaces**: file-tree editor, marketplace (publish/gallery/copy).

2A and 2B are independent after the `bundle_sha` attribute lands (2A owns it); Plan 3 depends on 2B's Export.

## Affected and new modules (indicative)

New: `lib/magus/skills/loader.ex`, `lib/magus/skills/conversation_skill_approval.ex`, `lib/magus/skills/skill_trust.ex`, `lib/magus/skills/sandbox_secret.ex`, `lib/magus/skills/export.ex`, `lib/magus/skills/import/url_fetcher.ex`, `lib/magus/skills/import/agents_md.ex`.

Modified: `lib/magus/agents/slash_commands.ex` (skills source + resolve/3), `lib/magus/agents/plugins/support/preflight.ex` (deterministic load), `lib/magus/agents/tools/skills/load_skill.ex` (thin wrapper), `lib/magus/skills/materializer.ex` (secrets + preinstall), `lib/magus/skills/import.ex` + `import/unpack.ex` (dir entries, orphan cleanup), `lib/magus/skills/discovery.ex` (turn cache), `lib/magus/chat/conversation.ex` (drop array; `record_skill_approval` targets the join row), `lib/magus/agents/plugins/inbox_event_plugin.ex` (attribution), `lib/magus_web/workbench/controllers/skill_controller.ex` (download → export), `lib/magus_web/rpc/skills_controller.ex` (URL/md import params), SPA: `catalog.ts`, `notification-bell.svelte`, skill detail + settings routes, `api.ts`.
