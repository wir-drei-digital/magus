# Cloud Drive Providers (OneDrive, Dropbox, kDrive, generic WebDAV) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four knowledge-source providers for RAG sync: Microsoft OneDrive (Graph delta), Dropbox (cursor delta), Infomaniak kDrive (REST API, Manager-token auth), and a generic WebDAV provider (covers ownCloud, Koofr, Hetzner Storage Share, Fastmail, paid kDrive).

**Architecture:** Generalize the Google-only token refresh (`Magus.Knowledge.OAuth` + `TokenManager`) into a per-provider refresh config table. Each provider gets a `Magus.Knowledge.Connector` implementation modeled on the existing `google_drive.ex` (OAuth/delta providers) or `nextcloud.ex` (credential/WebDAV providers). OneDrive and Dropbox are OAuth wizard tiles reusing the existing shared `/oauth/:provider/{authorize,callback}` flow + session-stash finalize; kDrive and WebDAV are form tiles reusing the `connect_source` RPC. A new `{:error, :cursor_reset}` contract in IncrementalSync handles expired delta cursors (Graph 410 Gone, Dropbox 409 reset) by clearing the cursor and running one fallback etag sync, which also catches deletions missed in the gap.

**Tech Stack:** Elixir, Ash 3.x, Req, Bypass (tests), Microsoft Graph v1.0, Dropbox API v2, Infomaniak API v2/v3, WebDAV (PROPFIND).

## Verified API facts (2026-07-09 research, all 3-0 adversarially confirmed)

- **Graph delta**: `GET {base}/me/drive/items/{folder_id}/delta`; pages via `@odata.nextLink`, final page carries `@odata.deltaLink` (store as cursor, replay for changes). Deletions carry a `"deleted": {}` facet. Expired token → HTTP `410 Gone` → full resync. Scope `Files.Read` + `offline_access` (delegated, personal + work accounts). Microsoft ROTATES refresh tokens on every refresh (our persist-immediately handles this).
- **Dropbox delta**: init cursor `POST /2/files/list_folder/get_latest_cursor` (recursive true), changes via `POST /2/files/list_folder/continue`; entries tagged `file` / `folder` / `deleted` (DeletedMetadata). Expired cursor → HTTP 409 with `path/reset` style error tag. Files carry `content_hash` (ideal list-time etag) and `server_modified`. Refresh tokens are long-lived, NOT rotated; authorize needs `token_access_type=offline`.
- **kDrive REST**: `GET /2/drive` (list drives), `GET /3/drive/{drive_id}/files/{file_id}/files` (directory listing), `GET /3/drive/{drive_id}/files/{file_id}` (metadata), `GET /2/drive/{drive_id}/files/{file_id}/download`. Auth: `Authorization: Bearer <token>` where token is a user-created Manager token with Drive scope (long-lived). Rate limit 60 req/min. Root directory file id is documented in the API docs; the implementer verifies it live (expected `1`). Change feed exists (`/3/drive/{id}/activities`) but is v2 scope: v1 uses fallback etag sync.
- **WebDAV**: no delta; fallback etag sync via `getetag`/`getlastmodified` (exactly what `nextcloud.ex` does today).

## Global Constraints

- No em dashes in code, comments, docs, or copy. Use colons/periods/commas.
- Never run `mix ash.reset`. Schema/enum changes via `mix ash.codegen <name>`; apply ONLY to the isolated partition DB with `MIX_TEST_PARTITION` set.
- Test/compile prefix (TESTCMD): `set -a && source .env && set +a && export MIX_TEST_PARTITION=_wt_drives && MIX_ENV=test`
- `TESTCMD mix compile --warnings-as-errors` clean before every commit.
- Bypass JSON handlers set `put_resp_content_type("application/json")` before `resp/3`. Fixture users need `Magus.Generators.ensure_workspace_plan(user)`.
- Every connector HTTP base URL and every token URL must be configurable via `Application.get_env(:magus, <key>, <production default>)` with the production default byte-for-byte correct (established pattern: `:google_drive_base_url`, `:google_token_url`, `:notion_base_url`).
- New connectors follow the established semantics from the sync-hardening work: `external_etag` stores the LIST-TIME etag; the content hash guard lives downstream (`SyncHelpers.update_existing_file/5`); `deletes_in_delta?/0` is defined true ONLY when detect_changes emits `:deleted` entries; sync internals use `authorize?: false`, wizard paths use `actor:`.
- Env var names: `ONEDRIVE_CLIENT_ID`, `ONEDRIVE_CLIENT_SECRET`, `DROPBOX_APP_KEY`, `DROPBOX_APP_SECRET` (Dropbox's own naming). The human operator registers the apps (Azure portal, Dropbox App Console); nothing in this plan can self-provision them. Redirect URIs to register: `https://<host>/oauth/onedrive_knowledge/callback` and `https://<host>/oauth/dropbox_knowledge/callback` (plus `http://localhost:4000/...` for dev).
- Do NOT touch the classic LiveView workbench (lib/magus_web/legacy/). SPA + backend only.
- User decisions: kDrive v1 auth is a pasted Manager token (form provider, like Nextcloud); kDrive activities-feed delta and OneDrive/Dropbox reactive mid-run 401 refresh are explicit v2 follow-ups, NOT in this plan (proactive `ensure_fresh` covers the normal case; a mid-run expiry surfaces as one failed run that self-heals next cycle).

## File Structure

**New files:**
- `lib/magus/knowledge/connectors/onedrive.ex`, `dropbox.ex`, `kdrive.ex`, `webdav.ex`
- `lib/magus/knowledge/connectors/webdav/client.ex` (shared PROPFIND/XML/retry extracted from nextcloud.ex)
- `lib/magus/integrations/providers/onedrive_knowledge/provider.ex`, `dropbox_knowledge/provider.ex`
- `test/magus/knowledge/connectors/{onedrive,dropbox,kdrive,webdav}_test.exs`

**Modified:**
- `lib/magus/knowledge/oauth.ex` (per-provider refresh table)
- `lib/magus/knowledge/token_manager.ex` (refreshable-provider generalization)
- `lib/magus/knowledge/knowledge_source.ex` (enum: add `:dropbox`, `:kdrive`, `:webdav`; `:onedrive` already present)
- `lib/magus/knowledge/connect.ex` (`@providers`, `default_name/1`)
- `lib/magus/knowledge/connector.ex` (`connector_for/1` entries)
- `lib/magus/knowledge/connectors/nextcloud.ex` (delegate to shared WebDAV client)
- `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` (`{:error, :cursor_reset}` handling)
- `lib/magus/integrations/registry.ex` (`@builtins` + two entries)
- `frontend/src/lib/components/knowledge/knowledge-connect-wizard.svelte` (four tiles)
- `config/test.exs` (URL seams)
- `.env.example` if present (new env vars)

## Execution notes

- Canonical templates: `lib/magus/knowledge/connectors/google_drive.ex` (OAuth + delta + cursor + folder recursion + download caps) and `lib/magus/knowledge/connectors/nextcloud.ex` (credential provider + recursion + retry). Read the template BEFORE writing a connector; mirror its structure, naming, logging, and 100MB download cap.
- Canonical test templates: `test/magus/knowledge/connectors/google_drive_test.exs` (Bypass + base URL override) and the fake-Drive describe blocks in `test/magus/knowledge/knowledge_collection_test.exs`.
- Worktree setup (execution time): symlink `deps`/`.env`/`frontend/node_modules` from the main checkout, own `_build`, fresh partition DB via `TESTCMD mix ash.setup` with `MIX_TEST_PARTITION=_wt_drives`.

---

### Task 1: Generalize token refresh to a per-provider config table

**Files:**
- Modify: `lib/magus/knowledge/oauth.ex`
- Modify: `lib/magus/knowledge/token_manager.ex`
- Modify: `config/test.exs`
- Test: `test/magus/knowledge/oauth_test.exs`, `test/magus/knowledge/token_manager_test.exs`

**Interfaces:**
- Produces: `Magus.Knowledge.OAuth.refresh_token(provider :: :google_drive | :onedrive | :dropbox, refresh_token) :: {:ok, %{"access_token" => _, "refresh_token" => _, "expires_at" => _}} | {:error, :reauth_required | :missing_oauth_config | {:refresh_failed, _, _} | {:network_error, _}}`. The returned `"refresh_token"` is the rotated one when the provider issued one (Microsoft rotates), else the caller's.
- `refresh_google_token/1` remains as a delegating wrapper (back-compat for the Drive connector's reactive path).
- `TokenManager.ensure_fresh/1` refreshes for any provider in the refresh table (`:google_drive`, `:onedrive`, `:dropbox`); all other providers pass through unchanged.

- [ ] **Step 1: Failing tests.** In `oauth_test.exs`, add a describe "refresh_token/2 per provider" reusing the existing Bypass setup pattern, parameterized over the three providers: each gets its own Bypass, `Application.put_env` of its token URL key, and env creds. Assert: 200 with `refresh_token` in the response body returns the ROTATED token (Microsoft case); 200 without returns the caller's (Dropbox case); 400 `invalid_grant` → `{:error, :reauth_required}` for each provider. In `token_manager_test.exs`, add: a `:dropbox` source with expired `expires_at` refreshes and persists (mirror the existing google test with provider swapped); a `:nextcloud` source still passes through with no HTTP.

Provider config facts for the tests and implementation:

| provider | token URL config key | production default | client env vars |
|---|---|---|---|
| `:google_drive` | `:google_token_url` | `https://oauth2.googleapis.com/token` | `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` |
| `:onedrive` | `:onedrive_token_url` | `https://login.microsoftonline.com/common/oauth2/v2.0/token` | `ONEDRIVE_CLIENT_ID` / `ONEDRIVE_CLIENT_SECRET` |
| `:dropbox` | `:dropbox_token_url` | `https://api.dropboxapi.com/oauth2/token` | `DROPBOX_APP_KEY` / `DROPBOX_APP_SECRET` |

All three use `grant_type=refresh_token` form POST with client id/secret in the body and return standard OAuth JSON (`access_token`, optional `refresh_token`, `expires_in`); all three signal a dead refresh token with HTTP 400 and `"error": "invalid_grant"`.

- [ ] **Step 2: Implement.** Restructure `oauth.ex`: a private `@provider_config` map keyed by provider atom holding `%{token_url_key:, default_token_url:, client_id_env:, client_secret_env:}`; `credentials(provider)` and `refresh_token(provider, rt)` generalize the existing single-provider functions (same taxonomy, same logging with the provider name in the message). `refresh_google_token(rt)` becomes `def refresh_google_token(rt), do: refresh_token(:google_drive, rt)`. Keep `google_credentials/0` delegating similarly (the Drive connector and provider module call it).
- [ ] **Step 3: TokenManager.** Replace the `%{provider: :google_drive}` clause with `%{provider: p} = source when p in [:google_drive, :onedrive, :dropbox]` (module attribute `@refreshable`), and `do_refresh` calls `OAuth.refresh_token(source.provider, rt)`. Everything else (skew, persist-merge, reauth flagging) is provider-agnostic already.
- [ ] **Step 4: config/test.exs** gains the two new token URL entries with production defaults.
- [ ] **Step 5:** RED→GREEN, then `TESTCMD mix test test/magus/knowledge`, compile gate, commit `feat(knowledge): per-provider OAuth token refresh table`.

---

### Task 2: Enums, provider modules, registry, Connect list

**Files:**
- Modify: `lib/magus/knowledge/knowledge_source.ex:140-156` (add `:dropbox`, `:kdrive`, `:webdav` to the provider `one_of`)
- Create: `lib/magus/integrations/providers/onedrive_knowledge/provider.ex`, `lib/magus/integrations/providers/dropbox_knowledge/provider.ex`
- Modify: `lib/magus/integrations/registry.ex` (`@builtins`)
- Modify: `lib/magus/knowledge/connect.ex` (`@providers ~w(google_drive onedrive dropbox notion nextcloud kdrive webdav web)`, `default_name` clauses: "OneDrive", "Dropbox", "kDrive", "WebDAV")
- Modify: `.env.example` if it exists (four new env vars, commented)
- Migration: `mix ash.codegen add_drive_provider_enum_values` (snapshots only; inspect for unrelated drift as usual)
- Test: `test/magus/knowledge/connect_test.exs`

**Interfaces:**
- Produces: provider modules implementing `Magus.Integrations.Providers.Behaviour` with `source_type: :knowledge`, keys `:onedrive_knowledge` / `:dropbox_knowledge`, and `oauth_config/0` consumed by the shared `MagusWeb.OAuthController`:

```elixir
# onedrive_knowledge/provider.ex oauth_config/0
%{
  authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
  token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
  scopes: ["Files.Read", "offline_access"],
  client_id: System.get_env("ONEDRIVE_CLIENT_ID"),
  client_secret: System.get_env("ONEDRIVE_CLIENT_SECRET")
}
```

```elixir
# dropbox_knowledge/provider.ex oauth_config/0
%{
  authorize_url: "https://www.dropbox.com/oauth2/authorize",
  token_url: "https://api.dropboxapi.com/oauth2/token",
  scopes: ["files.metadata.read", "files.content.read"],
  client_id: System.get_env("DROPBOX_APP_KEY"),
  client_secret: System.get_env("DROPBOX_APP_SECRET"),
  extra_authorize_params: %{token_access_type: "offline"}
}
```

Model both modules on `google_drive_knowledge/provider.ex` (same callbacks: `key`, `name`, `description`, `auth_type: :oauth2`, `operations: []`, `execute -> {:error, :not_supported}`, `source_type: :knowledge`, `requires_admin?: true`). NOTE the shared OAuthController already appends `access_type=offline&prompt=consent` to every authorize URL; Microsoft ignores `access_type` and honors `prompt=consent`, Dropbox ignores both: verify nothing breaks by reading `oauth_controller.ex:31-43`, do not modify the controller.

- [ ] **Step 1: Failing test.** `connect_test.exs`: assert `Connect.providers()` equals the new list, and `default_name` behavior via `connect_and_create` for a WebDAV-shaped provider is NOT yet testable (connector missing until Task 6); test only the list + that `parse_provider` accepts "onedrive"/"dropbox"/"kdrive"/"webdav" (via `connect_and_create` returning a connector-level error rather than "Unknown provider").
- [ ] **Step 2: Implement all files above.** `Connector.connector_for/1` entries for the four new atoms land in their respective connector tasks; in THIS task add them pointing at the module names with the modules not yet existing? NO: `connector_for/1` returns module atoms unchecked, but `Connect.connect_and_create` calls `module.connect/1` which would raise `UndefinedFunctionError`. Therefore in this task add `connector_for` clauses ONLY for atoms whose connector ships in this plan AND guard the Connect test expectations accordingly: it is acceptable for `connect_and_create("onedrive", ...)` to fail with a connector error until Task 3 lands; each connector task flips its own test to full connect coverage.
- [ ] **Step 3:** `TESTCMD mix ash.codegen add_drive_provider_enum_values` (inspect: expect resource snapshot updates only, likely no SQL migration since the provider column is text; if codegen emits anything unrelated, exclude it), `TESTCMD mix ash.migrate` (partition only).
- [ ] **Step 4:** RED→GREEN, knowledge suite, compile gate, commit `feat(knowledge): provider scaffolding for onedrive, dropbox, kdrive, webdav`.

---

### Task 3: OneDrive connector (Graph delta) + `{:error, :cursor_reset}` framework contract

**Files:**
- Create: `lib/magus/knowledge/connectors/onedrive.ex`
- Modify: `lib/magus/knowledge/connector.ex` (`connector_for(:onedrive)`)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` (`:cursor_reset` handling in `do_sync`)
- Modify: `config/test.exs` (`:onedrive_api_base_url` default `https://graph.microsoft.com/v1.0`)
- Test: `test/magus/knowledge/connectors/onedrive_test.exs`, `test/magus/knowledge/knowledge_collection_test.exs` (cursor-reset integration)

**Interfaces:**
- Produces: `Magus.Knowledge.Connectors.Onedrive` implementing the full behaviour + `deletes_in_delta?, do: true`.
- Produces the framework contract every delta connector can use: `detect_changes` may return `{:error, :cursor_reset}`; IncrementalSync then clears the stored cursor (`update_sync_status` with `sync_cursor: %{}`), logs "Delta cursor expired: running full fallback sync", and runs `fallback_sync` in the same run (fallback's full-listing diff catches deletions missed in the gap). The NEXT incremental run re-bootstraps the cursor via the nil-cursor path.

**Connector spec** (mirror google_drive.ex structure; `base_url()` from config; auth `Bearer` from `auth_config["access_token"]`; struct `[:access_token]`):

| Callback | Graph call | Notes |
|---|---|---|
| `connect/1` | none | require non-empty `"access_token"`, like GoogleDrive |
| `list_folders/2` | `GET /me/drive/root/children` (path nil) or `GET /me/drive/items/{id}/children` | keep entries with a `"folder"` facet; folder `%{id: item["id"], name: item["name"], path: "/" <> item["id"]}`; follow `@odata.nextLink` pages (GET the absolute URL as-is) |
| `list_items/3` | children recursion over the collection folder id, mirroring GoogleDrive's folder-queue cursor pattern | item: `id`, `name`, `etag: item["cTag"] || item["eTag"]` (cTag changes only on content change), `updated_at: parse(item["lastModifiedDateTime"])`, `mime_type: get_in(item, ["file", "mimeType"]) || "application/octet-stream"`; skip entries with a `"folder"` facet in file listing and enqueue them for recursion |
| `fetch_content/2` | `GET /me/drive/items/{id}/content` | Graph 302-redirects to a pre-signed URL; Req follows redirects by default, verify `redirect: true` semantics; enforce the 100MB cap and 300s timeout like GoogleDrive |
| `detect_changes/3` | cursor nil → `GET /me/drive/items/{folder_id}/delta`, drain ALL pages via `@odata.nextLink`, DISCARD the items (initial enumeration; full sync owns creation), return `{:ok, [], %{"sync_cursor" => delta_link}}`. Cursor present → GET the stored deltaLink URL, drain pages: entries with `"deleted"` facet → `%{type: :deleted, item: %{id: id}}`; folder-facet entries skipped; others → `:updated` with the same item shape as list_items. Return final `@odata.deltaLink` as the new cursor. HTTP 410 → `{:error, :cursor_reset}` | the deltaLink/nextLink are ABSOLUTE URLs: in test env they point at Bypass because the fake returns links built from the request host; the connector must call them verbatim, not re-prefix base_url |
| `register_webhook/create_item/update_item` | `{:error, :not_supported}` | |
| `deletes_in_delta?/0` | `true` | |

- [ ] **Step 1: Failing connector tests** (Bypass, base URL override): connect validation; list_folders folder-facet filtering + nextLink pagination (two pages); list_items shape incl. cTag etag; detect_changes bootstrap (nil cursor → empty changes + stored deltaLink); detect_changes with cursor (one deleted facet + one updated + one folder-skipped); 410 → `{:error, :cursor_reset}`.
- [ ] **Step 2: Failing integration test** in knowledge_collection_test.exs: an `:onedrive` source + collection with a stored cursor whose delta endpoint returns 410, plus list endpoints for the fallback listing; after `do_incremental_sync`: collection `:synced` via fallback, cursor cleared (`sync_cursor == %{}`), and a locally-present-but-remotely-absent file was hard-deleted by the fallback diff (proves the missed-deletions-in-gap property).
- [ ] **Step 3: Implement** connector + the `do_sync` clause:

```elixir
      {:error, :cursor_reset} ->
        SyncLogger.warn(cid, "Delta cursor expired: running full fallback sync")

        {:ok, _} =
          Magus.Knowledge.update_sync_status(collection, %{sync_cursor: %{}}, authorize?: false)

        fallback_sync(conn, connector, collection, source, actor)
```

placed between the `:not_supported` and `:reauth_required` clauses.
- [ ] **Step 4:** RED→GREEN, knowledge suite, compile gate, commit `feat(knowledge): OneDrive connector with Graph delta and cursor-reset recovery`.

---

### Task 4: Dropbox connector

**Files:**
- Create: `lib/magus/knowledge/connectors/dropbox.ex`
- Modify: `lib/magus/knowledge/connector.ex` (`connector_for(:dropbox)`)
- Modify: `config/test.exs` (`:dropbox_api_base_url` default `https://api.dropboxapi.com`, `:dropbox_content_base_url` default `https://content.dropboxapi.com`)
- Test: `test/magus/knowledge/connectors/dropbox_test.exs`

**Interfaces:** `Magus.Knowledge.Connectors.Dropbox`, full behaviour + `deletes_in_delta?, do: true`. All RPC endpoints are `POST` with JSON bodies and `Authorization: Bearer`; the content endpoint uses the `Dropbox-API-Arg` header.

| Callback | Dropbox call | Notes |
|---|---|---|
| `connect/1` | none | require `"access_token"` |
| `list_folders/2` | `POST {api}/2/files/list_folder` body `%{path: path || "", recursive: false}` (+ `list_folder/continue` on `has_more`) | keep `.tag == "folder"` entries; folder `%{id: e["id"], name: e["name"], path: e["path_display"]}`. Root is `""` not `"/"`: map nil → `""` |
| `list_items/3` | `POST /2/files/list_folder` body `%{path: collection_path(collection), recursive: true}`; cursor continuation via `%{"cursor" => c}` → `list_folder/continue` | item: `id: e["id"]`, `name`, `etag: e["content_hash"]`, `updated_at: parse(e["server_modified"])`, `mime_type: "application/octet-stream"`; skip `folder` tags; `collection_path/1`: use the collection's `external_path` (folder path) when present, else external_id; store cursor in the 3-tuple return while `has_more` |
| `fetch_content/2` | `POST {content}/2/files/download`, headers `Dropbox-API-Arg: Jason.encode!(%{path: item_id})`, empty body | binary response body; 100MB cap, 300s timeout |
| `detect_changes/3` | cursor nil → `POST /2/files/list_folder/get_latest_cursor` body `%{path: collection_path, recursive: true}` → `{:ok, [], %{"sync_cursor" => cursor}}`. Cursor → `POST /2/files/list_folder/continue` looped on `has_more`: `.tag "deleted"` → `:deleted` (id: DeletedMetadata has NO id: use `e["path_lower"]`; see below), `.tag "file"` → `:updated`, `"folder"` skipped. HTTP 409 whose body error tag is a reset → `{:error, :cursor_reset}` |
| `deletes_in_delta?/0` | `true` | |

**Dropbox identity caveat (design decision baked into this task):** `DeletedMetadata` carries paths, not file ids. Therefore for Dropbox the item identity (`item.id`, hence File.external_id) is `path_lower`, NOT the Dropbox file id: this makes create/update/delete correlate correctly at the cost of treating a moved file as delete+create (matches Drive-connector behavior for moves outside tracked folders). Document this in the connector moduledoc.

- [ ] **Step 1: Failing tests**: connect; list_folders (folder filtering, root `""` mapping, has_more continuation); list_items shape (content_hash etag, path_lower id, folder skip, cursor continuation); fetch_content (correct content host + Dropbox-API-Arg header assertion via Bypass request inspection); detect_changes bootstrap; delta with one DeletedMetadata + one file entry; 409 reset body → `{:error, :cursor_reset}`.
- [ ] **Step 2: Implement** (mirror structure/logging of google_drive.ex; two base URLs).
- [ ] **Step 3:** RED→GREEN, knowledge suite, compile gate, commit `feat(knowledge): Dropbox connector with cursor delta`.

---

### Task 5: kDrive connector (Manager token, fallback sync)

**Files:**
- Create: `lib/magus/knowledge/connectors/kdrive.ex`
- Modify: `lib/magus/knowledge/connector.ex` (`connector_for(:kdrive)`)
- Modify: `config/test.exs` (`:kdrive_api_base_url` default `https://api.infomaniak.com`)
- Test: `test/magus/knowledge/connectors/kdrive_test.exs`

**Interfaces:** `Magus.Knowledge.Connectors.Kdrive`. Auth config `%{"api_token" => token}` (Bearer). NO `deletes_in_delta?` (detect_changes returns `{:error, :not_supported}` → fallback etag sync handles updates AND deletions; the activities feed is a documented v2 follow-up).

**Identity scheme:** kDrive scopes everything by `drive_id` + `file_id`. Composite ids: folders/items use `"{drive_id}:{file_id}"`; `list_folders(conn, nil)` lists DRIVES (`GET /2/drive`, each drive → folder `%{id: "#{drive_id}:root", name: drive_name, path: "/#{drive_id}"}`); `list_folders(conn, "{drive_id}:{file_id}")` lists child directories via `GET /3/drive/{drive_id}/files/{file_id}/files` filtered to directories. The root file id: verify against the live docs JSON at developer.infomaniak.com (expected literal `1`); encode the verified value as a module attribute with a comment citing the doc.

| Callback | kDrive call | Notes |
|---|---|---|
| `list_items/3` | `GET /3/drive/{drive_id}/files/{file_id}/files` recursively (directory walk like nextcloud.ex's recursion, max depth 10) | item: `id: "#{drive_id}:#{file["id"]}"`, `name`, `etag: to_string(file["revised_at"] || file["updated_at"])`, `updated_at` from the same field (epoch seconds per Infomaniak convention: verify and parse accordingly), `mime_type: file["mime_type"] || "application/octet-stream"`; response envelope is `%{"data" => [...]}` with cursor pagination fields: handle `has_more`/cursor if the live docs show them, else plain list |
| `fetch_content/2` | `GET /2/drive/{drive_id}/files/{file_id}/download` | binary; 100MB cap |
| `detect_changes/3` | `{:error, :not_supported}` | fallback sync path |
| everything else | `{:error, :not_supported}` | |

Rate-limit note for the moduledoc: the API allows 60 req/min; the recursive listing paces itself naturally at current collection sizes, and the app-level RateLimiter caps sync frequency; if large drives hit 429, the connector reuses the capped Retry-After retry helper pattern from nextcloud.ex (implement `request_with_retry` the same way, cap 15s).

- [ ] **Step 1: Failing tests** (Bypass): connect validation (missing token); list_folders nil → drives mapping; list_folders composite id → directory filtering; list_items recursion (one subdir, files aggregated, composite ids, etag from revised_at); fetch_content path; 429 retry honored once then success.
- [ ] **Step 2: Implement.**
- [ ] **Step 3:** RED→GREEN, knowledge suite, compile gate, commit `feat(knowledge): Infomaniak kDrive connector (Manager token)`.

---

### Task 6: Generic WebDAV: extract shared client, new connector

**Files:**
- Create: `lib/magus/knowledge/connectors/webdav/client.ex`
- Create: `lib/magus/knowledge/connectors/webdav.ex`
- Modify: `lib/magus/knowledge/connectors/nextcloud.ex` (delegate to the shared client)
- Modify: `lib/magus/knowledge/connector.ex` (`connector_for(:webdav)`)
- Test: `test/magus/knowledge/connectors/webdav_test.exs`; existing `nextcloud_test.exs` must stay green unchanged (proves the extraction is behavior-preserving)

**Interfaces:**
- `Webdav.Client` owns everything currently generic in nextcloud.ex: `propfind/4` (conn-agnostic: takes base_url + auth headers), `request_with_retry/5`, `parse_multistatus/1`, `parse_datetime/1`, href/path encoding helpers. Nextcloud keeps ONLY: its auth-config shape, `/remote.php/dav/files/{username}` path building, and `relative_path/2`.
- `Magus.Knowledge.Connectors.Webdav`: auth `%{"base_url" => dav_root_url, "username" => u, "password" => p}` where `base_url` IS the DAV collection root (no path magic): folder/list/fetch semantics identical to Nextcloud with prefix `""`. Moduledoc names the targets: ownCloud, Koofr, Hetzner Storage Share, Fastmail Files, kDrive paid tiers.

- [ ] **Step 1:** Run `nextcloud_test.exs` green as the baseline snapshot.
- [ ] **Step 2: Failing webdav tests**: mirror `nextcloud_test.exs`'s connect/parse cases with generic paths (no `/remote.php` anywhere), plus one Bypass PROPFIND round-trip listing a folder + file with etag.
- [ ] **Step 3: Extract + implement.** Mechanical extraction first (nextcloud green proves parity), then the thin generic connector.
- [ ] **Step 4:** RED→GREEN, knowledge suite, compile gate, commit `feat(knowledge): generic WebDAV connector via shared client extraction`.

---

### Task 7: SPA wizard tiles + rate-limit mappings + finalize glue check

**Files:**
- Modify: `frontend/src/lib/components/knowledge/knowledge-connect-wizard.svelte:34-75` (four new PROVIDERS entries)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex` (`check_rate_limit` provider mapping: `:onedrive -> :onedrive_knowledge`, `:dropbox -> :dropbox_knowledge`, `:kdrive -> :kdrive_knowledge`, `:webdav -> :webdav_knowledge`)
- Test: `test/magus/knowledge/connect_test.exs` (form providers end-to-end through `connect_source`)

**Wizard entries** (match the existing shapes exactly):

```ts
{ key: 'onedrive', label: 'OneDrive', kind: 'oauth', oauthKey: 'onedrive_knowledge',
  hint: 'Sign in with Microsoft to browse your OneDrive folders.' },
{ key: 'dropbox', label: 'Dropbox', kind: 'oauth', oauthKey: 'dropbox_knowledge',
  hint: 'Authorize Dropbox to sync selected folders.' },
{ key: 'kdrive', label: 'Infomaniak kDrive', kind: 'form',
  hint: 'Paste an API token created in the Infomaniak Manager (Drive scope).',
  fields: [{ name: 'api_token', label: 'API token', type: 'password' }] },
{ key: 'webdav', label: 'WebDAV', kind: 'form',
  hint: 'Any WebDAV server: ownCloud, Koofr, Hetzner Storage Share, Fastmail.',
  fields: [
    { name: 'base_url', label: 'WebDAV URL', type: 'url', placeholder: 'https://dav.example.com/files/user' },
    { name: 'username', label: 'Username', type: 'text' },
    { name: 'password', label: 'Password or app password', type: 'password' }
  ] }
```

- [ ] **Step 1: Failing backend test**: `connect_source` RPC action with provider "webdav" and a Bypass-served DAV root creates an active source; provider "kdrive" with a Bypass drives endpoint does the same (these are the wizard's exact server calls; OAuth tiles reuse the already-tested google flow with only the key changing, verified by asserting `Magus.Integrations.Registry.get(:onedrive_knowledge)` and `(:dropbox_knowledge)` return modules whose `source_type()` is `:knowledge` and whose `oauth_config()` carries the right authorize URL).
- [ ] **Step 2: Implement** wizard entries + mappings. Frontend check: `cd frontend && npx svelte-check --threshold error` if available, else the vite build (`npm run build`) compiles.
- [ ] **Step 3:** RED→GREEN, knowledge suite, compile gate, commit `feat(spa): connect wizard tiles for OneDrive, Dropbox, kDrive, WebDAV`.

---

### Task 8: Full regression + operator runbook

**Files:** `docs/superpowers/plans/2026-07-09-cloud-drive-providers.md` (append runbook) or PR body.

- [ ] **Step 1:** `TESTCMD mix test test/magus/knowledge test/magus/files test/magus_web/rpc` green; then `TESTCMD mix test` (whole suite) green; compile gate; `mix format` (revert any out-of-scope churn, as established).
- [ ] **Step 2: Operator runbook** (goes in the PR body): Azure portal app registration (single-tenant vs "personal + org" multitenant account type, delegated `Files.Read` + `offline_access`, redirect URIs dev+prod, client secret → `ONEDRIVE_CLIENT_ID/SECRET`); Dropbox App Console (scoped app, `files.metadata.read` + `files.content.read`, redirect URIs, key/secret → `DROPBOX_APP_KEY/SECRET`); kDrive/WebDAV need no registration. Note: Microsoft tenant admins can block consent for work accounts; unverified-publisher consent screens appear until publisher verification is completed (optional follow-up).
- [ ] **Step 3:** Commit any doc changes; done.

---

## Self-Review Notes

- **Coverage:** OneDrive → T1/T2/T3; Dropbox → T1/T2/T4; kDrive (Manager token, per user decision) → T2/T5; generic WebDAV → T6; wizard/UX → T7; refresh generalization pays for all OAuth providers → T1. Research verdicts honored: Proton and iCloud excluded (infeasible; Proton revisit ~end 2026), kDrive uses REST not paid-gated WebDAV.
- **Deliberate v2 follow-ups (record in PR):** kDrive activities-feed delta (`/3/drive/{id}/activities`, cursor semantics undocumented); reactive mid-run 401 refresh for OneDrive/Dropbox (Google has it; new providers self-heal next run); Dropbox longpoll/webhooks; Graph drive picker for multiple drives (v1 uses `/me/drive` default drive only); Box as next researched candidate.
- **Type consistency:** all connectors return the behaviour's item/folder/change shapes; `detect_changes` cursor maps use the `%{"sync_cursor" => _}` convention (GoogleDrive precedent); `{:error, :cursor_reset}` introduced in T3 and consumed by T4; `deletes_in_delta?` true only for OneDrive/Dropbox (kDrive/WebDAV rely on fallback diff).
- **Risk notes for implementers:** Graph deltaLink/nextLink are absolute URLs (test fakes must emit Bypass-host links; connector calls them verbatim); Dropbox identity = `path_lower` (documented tradeoff); kDrive root file id and timestamp format must be verified against live docs before hardcoding; the enum codegen may surface unrelated snapshot drift: exclude it.
