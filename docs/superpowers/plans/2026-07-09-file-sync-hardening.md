# File Sync Hardening (P0-P2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make external-data-source sync (Google Drive, Notion, Nextcloud, web) correct and robust for RAG: new files are picked up, updated files replace their chunks instead of duplicating them, remote deletions actually remove content, transient failures retry, and quota/etag/scheduling asymmetries are fixed.

**Architecture:** Consolidate the file-update path into one shared `SyncHelpers.update_existing_file/5` with a content-hash guard (skip re-store/re-process when bytes are unchanged) and quota enforcement. Fix the Drive delta create-if-missing hole. Make `external_etag` consistently store the list-time etag. Replace sync-driven soft deletes with hard deletes (user-initiated trash stays soft). Add chunk replacement on reprocess, bounded automatic retries for transient processing failures, a stuck-sync watchdog, and Notion delete reconciliation via a new optional connector capability callback.

**Tech Stack:** Elixir, Ash 3.x + AshPostgres, AshOban triggers, Req, Bypass (tests), pgvector.

## Global Constraints

- No em dashes in code, comments, docs, or copy. Use colons/periods/commas.
- Never run `mix ash.reset`. Schema changes via `mix ash.codegen <name>` then `MIX_ENV=test mix ash.migrate` applied ONLY to the isolated partition DB.
- All test/compile commands MUST use the isolated partition DB:
  `set -a && source .env && set +a && export MIX_TEST_PARTITION=_wt_sync && MIX_ENV=test mix test <path>`
- `MIX_ENV=test mix compile --warnings-as-errors` must be clean before every commit.
- Call resources through domain code interfaces (`Magus.Files.*`, `Magus.Knowledge.*`). `authorize?: false` is allowed only inside sync/processing internals (existing convention).
- Bypass JSON handlers must call `Plug.Conn.put_resp_content_type("application/json")` before `resp/3` (Req only auto-decodes JSON with the header).
- Test fixture users need a usage plan or every connector file fails quota with "0 B": call `Magus.Generators.ensure_workspace_plan(user)` after `generate(user())` in any test that syncs files.
- The `File` resource has `base_filter expr(is_nil(deleted_at))` (lib/magus/files/file.ex:36). Reads/updates/destroys through Ash do NOT see soft-deleted rows; the `IncludeTrashed` preparation pattern (lib/magus/files/file/preparations/include_trashed.ex) exists for bypassing it in reads.
- Do NOT touch the classic LiveView workbench (lib/magus_web/legacy/). SPA + backend only.
- User decisions already made: AFFiNE is removed from the connect wizard (backend list); sync-detected remote deletions HARD delete immediately (no trash, no grace period); quota-exceeded updates keep the old content and count as item errors.
- There is NO retroactive purge of already-soft-deleted connector files: sync-soft-deleted and user-trashed connector files are indistinguishable, and purging would empty users' intentional trash. Forward-looking hard deletes only.

## File Structure

**Modified (core):**
- `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex` — gains shared `update_existing_file/5` (hash guard + quota), `delete_remote_gone_file/1`, `content_hash/1`, `format_sync_error/1` additions.
- `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` — delta create-if-missing, hard deletes, Notion reconciliation, fallback nil-etag rule, completion-attrs changes; loses its private `update_existing_file/soft_delete_file`.
- `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex` — etag source fix, content_hash in metadata, update + delete support, friendlier failure attrs.
- `lib/magus/knowledge/knowledge_collection.ex` — watchdog trigger + `mark_sync_interrupted` action + incremental `where` guard.
- `lib/magus/knowledge/connector.ex` — optional `deletes_in_delta?/0` callback.
- `lib/magus/knowledge/connectors/google_drive.ex` — `deletes_in_delta?/0` returning true.
- `lib/magus/knowledge/connectors/web/web.ex` — `translate_item` surfaces lastmod as etag.
- `lib/magus/knowledge/connectors/notion.ex` — configurable base URL, Retry-After cap.
- `lib/magus/knowledge/connectors/nextcloud.ex` — Retry-After cap.
- `lib/magus/knowledge/connect.ex` — drop `affine` from `@providers`.
- `lib/magus/files/file.ex` — `update_from_connector` accepts `:metadata`; new attrs `processing_attempts`, `transient_error`; `update_status` accepts them; `reprocess` action; retry trigger.
- `lib/magus/files/files.ex` — `define :destroy_file` and `define :reprocess_file`.
- `lib/magus/files/file/changes/process_file.ex` — chunk replacement + transient/permanent error classification.
- `lib/magus/files/embedding_model.ex` — configurable embeddings URL (test seam).
- `config/test.exs` — embeddings URL default entry.

**Tests:** extend `test/magus/knowledge/knowledge_collection_test.exs` (Bypass fake-Drive pattern already exists there), `test/magus/knowledge/connectors/web/web_test.exs` (or create), `test/magus/files/file/process_file_chunks_test.exs` (create), `test/magus/knowledge/connect_test.exs`.

## Execution notes for every task

- Test command prefix (call it TESTCMD below):
  `set -a && source .env && set +a && export MIX_TEST_PARTITION=_wt_sync && MIX_ENV=test`
- The knowledge_collection_test.exs "sync reauth handling" describe block (added by the OAuth branch) shows the exact Bypass fake-Drive + fake-token setup to copy: token bypass on `POST /token`, drive bypass with `Application.put_env(:magus, :google_drive_base_url, ...)`, `System.put_env("GOOGLE_CLIENT_ID"/"SECRET", ...)`, `on_exit` restore. Reuse that shape; do not invent a new one.
- A fake Drive `GET /files` handler must distinguish folder discovery from file listing by checking `String.contains?(q, "mimeType='application/vnd.google-apps.folder'")` (equality string). The file-listing query contains `mimeType != '...'` which must NOT match.

---

### Task 1: Shared update path: content-hash guard, quota on update, etag consistency

The foundation task. Everything else that updates files goes through this.

**Files:**
- Modify: `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex`
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex:383-438` (remove private helpers, adapt callers, widen `get_existing_files`)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex:203-251` (`create_file_from_item` etag + hash)
- Modify: `lib/magus/files/file.ex:554-578` (`update_from_connector` accepts `:metadata`)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Produces: `SyncHelpers.update_existing_file(conn, connector, file, item, actor) :: {:ok, :updated} | {:ok, :unchanged} | {:error, term}`; `SyncHelpers.content_hash(binary) :: String.t()`.
- Semantics later tasks rely on: `external_etag` stores the LIST-TIME etag (`item.etag`), never the fetch-time hash; the content hash lives in `file.metadata["content_hash"]`; `{:ok, :unchanged}` means no re-store, no `:pending`, no new chunks.
- Latent bug fixed here: `get_existing_files/1` selects only `[:id, :external_id, :external_etag]`, so `file.file_path`/`file.user_id` in the old update path were never really loaded. Remove the `Ash.Query.select` entirely (collections are hundreds of rows; full reads are fine).

- [ ] **Step 1: Write the failing test** (append to `test/magus/knowledge/knowledge_collection_test.exs`; reuse the existing Bypass fake-Drive setup pattern):

```elixir
  describe "update path: hash guard + quota" do
    setup do
      drive = Bypass.open()
      prev = Application.get_env(:magus, :google_drive_base_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive.port}")
      on_exit(fn -> Application.put_env(:magus, :google_drive_base_url, prev) end)
      {:ok, drive: drive}
    end

    defp gdrive_fixture(_ctx) do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{"access_token" => "tok", "refresh_token" => "rt"}
          },
          actor: user
        )

      {:ok, source} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Folder", external_id: "root", external_path: "/root"},
          actor: user
        )

      %{user: user, source: source, collection: collection}
    end

    defp existing_file(user, collection, body) do
      hash = Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.content_hash(body)

      {:ok, file} =
        Magus.Files.create_file_from_connector(
          %{
            name: "doc.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: byte_size(body),
            file_path: "test/#{Ash.UUIDv7.generate()}.txt",
            knowledge_collection_id: collection.id,
            external_id: "file-1",
            external_etag: "etag-old",
            external_updated_at: DateTime.utc_now(),
            metadata: %{"content_hash" => hash}
          },
          actor: user
        )

      file
    end

    test "unchanged content skips re-store and does not flip status to :pending", ctx do
      %{user: user, collection: collection} = gdrive_fixture(ctx)
      body = "same content"
      file = existing_file(user, collection, body)
      {:ok, _} = Magus.Files.update_file_status(file, %{status: :ready}, authorize?: false)

      Bypass.expect(ctx.drive, "GET", "/files/file-1", fn conn ->
        Plug.Conn.resp(conn, 200, body)
      end)

      {:ok, conn} =
        Magus.Knowledge.Connectors.GoogleDrive.connect(%{"access_token" => "tok"})

      item = %{id: "file-1", name: "doc.txt", etag: "etag-new", updated_at: DateTime.utc_now(), mime_type: "text/plain"}

      assert {:ok, :unchanged} =
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.update_existing_file(
                 conn,
                 Magus.Knowledge.Connectors.GoogleDrive,
                 Magus.Files.get_file!(file.id, authorize?: false),
                 item,
                 user
               )

      reloaded = Magus.Files.get_file!(file.id, authorize?: false)
      assert reloaded.status == :ready
      assert reloaded.external_etag == "etag-new"
    end

    test "changed content re-stores, flips to :pending, and refreshes the stored hash", ctx do
      %{user: user, collection: collection} = gdrive_fixture(ctx)
      file = existing_file(user, collection, "old content")

      Bypass.expect(ctx.drive, "GET", "/files/file-1", fn conn ->
        Plug.Conn.resp(conn, 200, "new content")
      end)

      {:ok, conn} =
        Magus.Knowledge.Connectors.GoogleDrive.connect(%{"access_token" => "tok"})

      item = %{id: "file-1", name: "doc.txt", etag: "etag-new", updated_at: DateTime.utc_now(), mime_type: "text/plain"}

      assert {:ok, :updated} =
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.update_existing_file(
                 conn,
                 Magus.Knowledge.Connectors.GoogleDrive,
                 Magus.Files.get_file!(file.id, authorize?: false),
                 item,
                 user
               )

      reloaded = Magus.Files.get_file!(file.id, authorize?: false)
      assert reloaded.status == :pending

      assert reloaded.metadata["content_hash"] ==
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.content_hash("new content")
    end

    test "an update that exceeds max_upload_bytes keeps the old content", ctx do
      %{user: user, collection: collection} = gdrive_fixture(ctx)
      file = existing_file(user, collection, "old content")
      # ensure_workspace_plan gives max_upload_bytes 104_857_600; exceed it
      huge = String.duplicate("x", 104_857_601)

      Bypass.expect(ctx.drive, "GET", "/files/file-1", fn conn ->
        Plug.Conn.resp(conn, 200, huge)
      end)

      {:ok, conn} =
        Magus.Knowledge.Connectors.GoogleDrive.connect(%{"access_token" => "tok"})

      item = %{id: "file-1", name: "doc.txt", etag: "etag-new", updated_at: DateTime.utc_now(), mime_type: "text/plain"}

      assert {:error, {:quota_exceeded, _msg}} =
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.update_existing_file(
                 conn,
                 Magus.Knowledge.Connectors.GoogleDrive,
                 Magus.Files.get_file!(file.id, authorize?: false),
                 item,
                 user
               )

      reloaded = Magus.Files.get_file!(file.id, authorize?: false)
      assert reloaded.external_etag == "etag-old"
    end
  end
```

Note: if `Magus.Files.get_file!/2` or `update_file_status/3` code interfaces differ, use the ones defined in `lib/magus/files/files.ex` (`define :get_file, action: :read, get_by: [:id]`, `define :update_file_status, action: :update_status`). If `update_status` does not accept `:status` transitions used here, adjust the fixture to create in the desired state instead.

- [ ] **Step 2: Run to verify failure**: `TESTCMD mix test test/magus/knowledge/knowledge_collection_test.exs` fails with `SyncHelpers.update_existing_file/5 is undefined` (and `content_hash/1`).

- [ ] **Step 3: Implement `SyncHelpers` additions** (append to `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex`; add `alias Magus.Files.Storage` and `require Logger` if missing):

```elixir
  @doc "SHA-256 hex digest used as the stored content fingerprint."
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Fetch remote content for `item` and update the local `file`.

  Layers, in order:
    1. Content-hash guard: when the fetched bytes hash to the stored
       `metadata["content_hash"]`, only `external_etag`/`last_synced_at` are
       bumped. No re-store, no `:pending`, no new chunks.
    2. Quota: same limits as create. An oversized update keeps the old
       content and surfaces `{:error, {:quota_exceeded, msg}}` as an item error.

  Returns `{:ok, :updated}`, `{:ok, :unchanged}`, or `{:error, reason}`.
  """
  def update_existing_file(conn, connector, file, item, actor) do
    case apply(connector, :fetch_content, [conn, item]) do
      {:ok, content, metadata} ->
        hash = content_hash(content)

        if hash == (file.metadata || %{})["content_hash"] do
          touch_unchanged_file(file, item)
        else
          store_updated_file(file, item, content, metadata, hash, actor)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch_unchanged_file(file, item) do
    case Magus.Files.update_file_from_connector(
           file,
           %{external_etag: item.etag, last_synced_at: DateTime.utc_now()},
           authorize?: false
         ) do
      {:ok, _} -> {:ok, :unchanged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_updated_file(file, item, content, metadata, hash, actor) do
    effective_mime = Map.get(metadata || %{}, "export_mime", item.mime_type)
    file_size = byte_size(content)

    with :ok <- check_update_quota(actor, file_size),
         storage_path =
           file.file_path || Storage.generate_path(file.user_id, file.id, item.name),
         {:ok, _} <- store_content(storage_path, content),
         {:ok, _updated} <-
           Magus.Files.update_file_from_connector(
             file,
             %{
               external_etag: item.etag,
               external_updated_at: item.updated_at,
               last_synced_at: DateTime.utc_now(),
               status: :pending,
               file_path: storage_path,
               file_size: file_size,
               mime_type: effective_mime,
               metadata: Map.put(file.metadata || %{}, "content_hash", hash)
             },
             authorize?: false
           ) do
      {:ok, :updated}
    end
  end

  defp check_update_quota(actor, file_size) do
    case Magus.Usage.PolicyEnforcer.check_file_upload(actor, file_size) do
      {:ok, :allowed} ->
        :ok

      {:error, error} ->
        {:error, {:quota_exceeded, Magus.Usage.PolicyErrorMessage.message(error)}}
    end
  end

  defp store_content(path, content) do
    case Storage.store(path, content) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end
```

Check `Magus.Usage.PolicyEnforcer.check_file_upload/2` and `Magus.Usage.PolicyErrorMessage.message/1` exist with those names (see `lib/magus/files/file/validations/check_storage_limits.ex` for the exact call shape) and adjust if the error struct differs.

- [ ] **Step 4: Adapt `incremental_sync.ex`**:
  - Delete its private `update_existing_file/5` (lines 383-413) and keep `soft_delete_file/1` for now (Task 5 replaces it).
  - Change both call sites (`process_change` `:updated` clause line 232, fallback line 306) to `SyncHelpers.update_existing_file(conn, connector, file, item, actor)`. Both already match `{:ok, _}` so `:updated`/`:unchanged` both count as success. In the fallback branch, change the success log to reflect the outcome:

```elixir
                  case SyncHelpers.update_existing_file(conn, connector, file, item, actor) do
                    {:ok, :updated} ->
                      SyncLogger.info(cid, "Updated: #{item.name}")
                      {items + 1, errors}

                    {:ok, :unchanged} ->
                      {items + 1, errors}

                    {:error, reason} ->
                      Logger.warning(
                        "IncrementalSync fallback: failed to update #{item.id}: #{inspect(reason)}"
                      )

                      SyncLogger.error(cid, "Failed to update #{item.name}: #{inspect(reason)}")
                      {items, errors + 1}
                  end
```

  - In `fallback_sync`, replace the etag comparison `if file.external_etag != item.etag do` with the nil-safe rule (a nil list-time etag means "cannot tell, must check"; the hash guard prevents wasted reprocessing):

```elixir
                needs_check? = is_nil(item.etag) or file.external_etag != item.etag

                if needs_check? do
```

  - In `get_existing_files/1` (line 429), DELETE the `|> Ash.Query.select([:id, :external_id, :external_etag])` line so full records are loaded (fixes the latent `file_path`/`user_id` not-selected bug).
  - The fallback `:updated` clause in `process_change` (line 218-244) passes `actor` already; keep.

- [ ] **Step 5: Adapt `full_sync.ex` `create_file_from_item/6`** (lines 203-240): store the list-time etag and the content hash:

```elixir
        # external_etag is the LIST-TIME etag (item.etag): it is what future
        # list_items/detect_changes results are compared against. The
        # fetch-time content fingerprint lives in metadata["content_hash"]
        # and powers the update path's hash guard.
        case Storage.store(storage_path, content) do
          {:ok, _} ->
            Magus.Files.create_file_from_connector(
              %{
                name: item.name,
                type: detect_file_type(effective_mime),
                mime_type: effective_mime,
                file_size: file_size,
                file_path: storage_path,
                knowledge_collection_id: collection.id,
                external_id: item.id,
                external_etag: item.etag,
                external_updated_at: item.updated_at,
                metadata: %{
                  source_provider: source.provider,
                  "content_hash" => SyncHelpers.content_hash(content)
                }
              },
              actor: actor
            )
```

(The old `external_etag: Map.get(metadata || %{}, "etag", item.etag)` metadata override goes away. For Google Drive the metadata never carried "etag" so nothing changes; for web sources this stops the hash from masquerading as the list-time etag.)

- [ ] **Step 6: `update_from_connector` accepts `:metadata`** in `lib/magus/files/file.ex:557-565`: add `:metadata` to the accept list.

- [ ] **Step 7: Run the new describe block, then the full knowledge suite**:
  `TESTCMD mix test test/magus/knowledge/knowledge_collection_test.exs` then `TESTCMD mix test test/magus/knowledge` (expect all green; existing web connector tests may assert `etag: nil` behavior and are untouched by this task).

- [ ] **Step 8: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/knowledge_collection/changes/ lib/magus/files/file.ex \
  test/magus/knowledge/knowledge_collection_test.exs
git commit -m "feat(knowledge): shared update path with content-hash guard and quota enforcement"
```

---

### Task 2: Google Drive delta creates files it has never seen (P0)

**Files:**
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex:218-244` (the `:updated` clause)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Consumes: `FullSync.create_file_from_item/6` (already public), Task 1's shared update path.
- Produces: an `:updated` delta change for an unknown `external_id` creates the file instead of no-op.

- [ ] **Step 1: Write the failing test** (append; reuses the fake-Drive Bypass pattern, this time with the Changes API):

```elixir
  describe "delta sync picks up files added after the initial sync" do
    setup do
      drive = Bypass.open()
      prev = Application.get_env(:magus, :google_drive_base_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive.port}")
      on_exit(fn -> Application.put_env(:magus, :google_drive_base_url, prev) end)
      {:ok, drive: drive}
    end

    test "an :updated change for an unknown external_id creates the file", %{drive: drive} do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{"access_token" => "tok", "refresh_token" => "rt"}
          },
          actor: user
        )

      {:ok, source} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Folder", external_id: "root-folder", external_path: "/root"},
          actor: user
        )

      # Cursor already bootstrapped; backdate so should_sync? passes.
      {:ok, collection} =
        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :synced,
            sync_cursor: %{"sync_cursor" => "cur-1"},
            last_synced_at: DateTime.add(DateTime.utc_now(), -7200, :second)
          },
          authorize?: false
        )

      Bypass.stub(drive, "GET", "/changes", fn conn ->
        body = %{
          "newStartPageToken" => "cur-2",
          "changes" => [
            %{
              "fileId" => "file-new",
              "removed" => false,
              "file" => %{
                "id" => "file-new",
                "name" => "brand-new.txt",
                "mimeType" => "text/plain",
                "modifiedTime" => "2026-07-09T11:00:00Z",
                "md5Checksum" => "abc",
                "parents" => ["root-folder"]
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      # Subfolder discovery for the tracked-folder filter: no subfolders.
      Bypass.stub(drive, "GET", "/files", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"files" => []}))
      end)

      Bypass.stub(drive, "GET", "/files/file-new", fn conn ->
        Plug.Conn.resp(conn, 200, "hello new file")
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.IncrementalSync.do_incremental_sync(collection)

      require Ash.Query

      files =
        Magus.Files.File
        |> Ash.Query.filter(knowledge_collection_id == ^collection.id)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(files, &(&1.external_id == "file-new")),
             "expected the delta-reported new file to be created, got: #{inspect(Enum.map(files, & &1.external_id))}"
    end
  end
```

- [ ] **Step 2: Run to verify failure**: the file list is empty (the `:updated` clause no-ops on unknown ids).

- [ ] **Step 3: Implement**: in `process_change/7`'s `:updated` clause, replace the `nil -> :ok` branch:

```elixir
    case Map.get(existing, item.id) do
      nil ->
        # Google Drive's Changes API reports newly added files as :updated.
        # An update for an item we have never synced is a create, not a no-op.
        process_change(
          conn,
          connector,
          %{type: :created, item: item},
          existing,
          collection,
          source,
          actor
        )
```

Note the `:updated` clause currently discards `collection`/`source` (`_collection, _source`); rename them back to `collection, source` since the redispatch needs them. No recursion risk: `:created` with an id absent from `existing` goes straight to create.

- [ ] **Step 4: Run the test to verify it passes, then the whole file.**

- [ ] **Step 5: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex \
  test/magus/knowledge/knowledge_collection_test.exs
git commit -m "fix(knowledge): Drive delta creates files it has never seen instead of dropping them"
```

---

### Task 3: Web connector surfaces lastmod as the list-time etag

**Files:**
- Modify: `lib/magus/knowledge/connectors/web/web.ex:227-240` (`translate_item/1`)
- Test: `test/magus/knowledge/connectors/web/web_test.exs` (extend; create the describe if absent)

**Interfaces:**
- Consumes: Task 1's rule that a nil list-time etag means "must check" (hash guard catches unchanged bytes downstream).
- Produces: sitemap entries with `<lastmod>` get a stable list-time etag, so unchanged pages are skipped WITHOUT even fetching. Pages without lastmod keep `etag: nil` and rely on the hash guard.

- [ ] **Step 1: Failing test** (in the web connector test file; follow its existing style):

```elixir
  describe "translate_item/1 etag" do
    test "uses last_modified metadata as the list-time etag" do
      item =
        Magus.Knowledge.Connectors.Web.translate_item(%{
          url: "https://example.com/docs/a",
          metadata: %{"last_modified" => "2026-07-01T00:00:00Z"}
        })

      assert item.etag == "2026-07-01T00:00:00Z"
    end

    test "etag stays nil without last_modified" do
      item = Magus.Knowledge.Connectors.Web.translate_item(%{url: "https://example.com/b", metadata: %{}})
      assert item.etag == nil
    end
  end
```

- [ ] **Step 2: Verify failure** (`etag: nil` hardcoded today at web.ex:235).

- [ ] **Step 3: Implement**: in `translate_item/1` change `etag: nil,` to `etag: Map.get(metadata, "last_modified"),` and update the function doc to say the lastmod string doubles as the list-time etag when present.

- [ ] **Step 4: Run web connector tests + the knowledge suite** (fallback interplay is covered by Task 1's nil-etag rule).

- [ ] **Step 5: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/connectors/web/web.ex test/magus/knowledge/connectors/web/
git commit -m "feat(knowledge): web connector surfaces sitemap lastmod as list-time etag"
```

---

### Task 4: Reprocessing replaces chunks instead of duplicating them (P0)

**Files:**
- Modify: `lib/magus/files/file/changes/process_file.ex:89-117` (`create_chunks_with_embeddings/2`)
- Modify: `lib/magus/files/embedding_model.ex:70-72` (configurable URL, test seam)
- Modify: `config/test.exs` (embeddings URL default)
- Test: Create `test/magus/files/file/process_file_chunks_test.exs`

**Interfaces:**
- Produces: running `:process` on a file that already has chunks deletes the old chunk rows in the same step that inserts the new ones. Chunk count stays equal to the latest processing result. Old chunks stop being searchable and stop re-feeding Super Brain.
- Test seam: `Application.get_env(:magus, :openrouter_embeddings_url, "https://openrouter.ai/api/v1/embeddings")`.

- [ ] **Step 1: Add the embeddings URL seam.** In `lib/magus/files/embedding_model.ex` `do_embed_request/3`, replace the hardcoded `url = "https://openrouter.ai/api/v1/embeddings"` with:

```elixir
    url =
      Application.get_env(:magus, :openrouter_embeddings_url, "https://openrouter.ai/api/v1/embeddings")
```

Add to `config/test.exs` next to `:google_token_url`:

```elixir
config :magus, :openrouter_embeddings_url, "https://openrouter.ai/api/v1/embeddings"
```

- [ ] **Step 2: Write the failing test** (`test/magus/files/file/process_file_chunks_test.exs`):

```elixir
defmodule Magus.Files.File.ProcessFileChunksTest do
  use Magus.ResourceCase, async: false

  require Ash.Query

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:magus, :openrouter_embeddings_url)
    Application.put_env(:magus, :openrouter_embeddings_url, "http://localhost:#{bypass.port}/embeddings")
    prev_key = Application.get_env(:magus, :openrouter_api_key)
    Application.put_env(:magus, :openrouter_api_key, "test-key")

    on_exit(fn ->
      Application.put_env(:magus, :openrouter_embeddings_url, prev)
      Application.put_env(:magus, :openrouter_api_key, prev_key)
    end)

    Bypass.stub(bypass, "POST", "/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => texts} = Jason.decode!(body)
      dim = 1536
      data = Enum.map(texts, fn _ -> %{"embedding" => List.duplicate(0.0, dim)} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => data}))
    end)

    {:ok, bypass: bypass}
  end

  defp stored_text_file(user, body) do
    path = "test/#{Ash.UUIDv7.generate()}.txt"
    {:ok, _} = Magus.Files.Storage.store(path, body)

    {:ok, file} =
      Magus.Files.create_file_from_connector(
        %{
          name: "doc.txt",
          type: :text,
          mime_type: "text/plain",
          file_size: byte_size(body),
          file_path: path,
          knowledge_collection_id: nil,
          external_id: nil
        },
        actor: user
      )

    file
  end

  defp chunk_count(file_id) do
    Magus.Files.Chunk
    |> Ash.Query.filter(file_id == ^file_id)
    |> Ash.count!(authorize?: false)
  end

  test "reprocessing replaces chunks instead of accumulating them" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "some short text content for chunking")

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)
    first = chunk_count(file.id)
    assert first > 0

    reloaded = Magus.Files.get_file!(file.id, authorize?: false)
    {:ok, _} = Ash.update(reloaded, %{}, action: :process, authorize?: false)

    assert chunk_count(file.id) == first,
           "expected reprocess to replace chunks, not duplicate them"
  end
end
```

Adjust the fixture if `create_from_connector` rejects `knowledge_collection_id: nil` (drop the key) or if the response shape the EmbeddingModel parses differs (read `lib/magus/files/embedding_model.ex:81-97` and match its expected `"data"`/`"embedding"` shape exactly).

- [ ] **Step 3: Verify failure**: second process doubles the chunk count.

- [ ] **Step 4: Implement**: in `process_file.ex`, add `require Ash.Query` at the top and change `create_chunks_with_embeddings/2` to destroy prior chunks after the embed succeeds and before inserting:

```elixir
    case EmbeddingModel.embed(texts) do
      {:ok, embeddings} ->
        # Replace prior chunks: reprocessing (connector updates set the file
        # back to :pending) must not leave stale rows behind. Old chunks stay
        # searchable until this point so a failed embed keeps the previous
        # generation intact.
        Magus.Files.Chunk
        |> Ash.Query.filter(file_id == ^file.id)
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: :atomic)

        chunks
        |> Enum.zip(embeddings)
        |> Enum.each(fn {chunk, embedding} ->
```

- [ ] **Step 5: Run the new test, then `TESTCMD mix test test/magus/files`** (expect green; note pre-existing failures per repo memory should not exist in this partition, investigate anything red).

- [ ] **Step 6: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/files/file/changes/process_file.ex lib/magus/files/embedding_model.ex \
  config/test.exs test/magus/files/file/process_file_chunks_test.exs
git commit -m "fix(files): reprocessing replaces chunks instead of duplicating them"
```

---

### Task 5: Bounded automatic retries for transient processing failures

**Files:**
- Modify: `lib/magus/files/file.ex` (two new attributes, `update_status` accepts, `reprocess` action, retry trigger)
- Modify: `lib/magus/files/files.ex` (`define :reprocess_file, action: :reprocess`)
- Modify: `lib/magus/files/file/changes/process_file.ex` (transient/permanent classification)
- Migration: `mix ash.codegen add_file_processing_retry_state`
- Test: extend `test/magus/files/file/process_file_chunks_test.exs`

**Interfaces:**
- Produces: attributes `processing_attempts :: integer` (default 0, `public? false`) and `transient_error :: boolean` (default false, `public? false`) on `File`. A transient failure (storage read, embedding API) marks `transient_error: true` and increments `processing_attempts`; a cron trigger re-runs `:process` for `status == :error and transient_error and processing_attempts < 4` every 30 minutes. Permanent failures (encoding, empty text, extraction) behave exactly as today. Manual recovery: `Magus.Files.reprocess_file/2`.

- [ ] **Step 1: Failing test** (append to the Task 4 test file):

```elixir
  test "an embedding API failure is transient: flagged for retry, then succeeds" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "text that will fail to embed the first time")

    # Route embeddings to a dead port for the first attempt.
    dead = Bypass.open()
    Bypass.down(dead)
    prev = Application.get_env(:magus, :openrouter_embeddings_url)
    Application.put_env(:magus, :openrouter_embeddings_url, "http://localhost:#{dead.port}/embeddings")

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)

    failed = Magus.Files.get_file!(file.id, authorize?: false)
    assert failed.status == :error
    assert failed.transient_error == true
    assert failed.processing_attempts == 1

    # Restore the working fake and reprocess manually (what the cron trigger does).
    Application.put_env(:magus, :openrouter_embeddings_url, prev)
    {:ok, _} = Magus.Files.reprocess_file(failed, authorize?: false)
    # reprocess sets :pending and enqueues; in tests run the action inline:
    pending = Magus.Files.get_file!(file.id, authorize?: false)
    {:ok, _} = Ash.update(pending, %{}, action: :process, authorize?: false)

    recovered = Magus.Files.get_file!(file.id, authorize?: false)
    assert recovered.status == :ready
    assert recovered.transient_error == false
  end

  test "an empty document is a permanent failure: no retry flag" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "   ")

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)

    failed = Magus.Files.get_file!(file.id, authorize?: false)
    assert failed.status == :error
    assert failed.transient_error == false
  end
```

- [ ] **Step 2: Verify failure** (attributes undefined).

- [ ] **Step 3: Resource changes** in `lib/magus/files/file.ex`:
  - Attributes (near `chunk_count`/`error_message`):

```elixir
    attribute :processing_attempts, :integer do
      allow_nil? false
      default 0
      public? false
      description "Transient processing failures so far; bounds the automatic retry cron."
    end

    attribute :transient_error, :boolean do
      allow_nil? false
      default false
      public? false
      description "Last processing failure was transient (storage/embedding); eligible for auto-retry."
    end
```

  - Extend `update :update_status` accepts with `:transient_error, :processing_attempts` (find the action at file.ex:337 and add to its accept list).
  - New action after `:process`:

```elixir
    update :reprocess do
      description "Manually or automatically re-run processing for a failed file."
      require_atomic? false
      change set_attribute(:status, :pending)
      change set_attribute(:transient_error, false)
      change run_oban_trigger(:process_file)
    end
```

  - New trigger inside `oban do triggers do`:

```elixir
      trigger :retry_transient_processing do
        action :reprocess
        queue :file_processing
        scheduler_cron "*/30 * * * *"
        where expr(status == :error and transient_error == true and processing_attempts < 4)
        worker_module_name Magus.Files.File.Workers.RetryTransientProcessing
        scheduler_module_name Magus.Files.File.Schedulers.RetryTransientProcessing
      end
```

  - `lib/magus/files/files.ex`: `define :reprocess_file, action: :reprocess`.

- [ ] **Step 4: Classification in `process_file.ex`.** Tag each pipeline step and branch on the class in the error handler:

```elixir
      result =
        with {:ok, content} <- classify(:transient, get_file_content(file)),
             {:ok, text} <- classify(:permanent, extract_text(file, content)),
             {:ok, chunks} <- classify(:permanent, chunk_text(text)),
             {:ok, _} <- classify(:transient, create_chunks_with_embeddings(file, chunks)) do
          update_status(file, :ready, %{chunk_count: length(chunks), transient_error: false})
          Logger.info("Successfully processed file #{file.id} with #{length(chunks)} chunks")
          {:ok, changeset}
        end

      case result do
        {:ok, changeset} ->
          changeset

        {:error, {class, reason}} ->
          error_message = format_error(reason)
          Logger.error("File processing failed for #{file.id} (#{class}): #{error_message}")

          extra =
            case class do
              :transient ->
                %{
                  error_message: error_message,
                  transient_error: true,
                  processing_attempts: (file.processing_attempts || 0) + 1
                }

              :permanent ->
                %{error_message: error_message, transient_error: false}
            end

          update_status(file, :error, extra)
          # No changeset error on purpose: the Oban job must succeed. Retries
          # happen via the retry_transient_processing cron, bounded by
          # processing_attempts.
          changeset
      end
```

with the helper:

```elixir
  defp classify(_class, {:ok, _} = ok), do: ok
  defp classify(_class, {:ok, _, _} = ok), do: ok
  defp classify(class, {:error, reason}), do: {:error, {class, reason}}
```

- [ ] **Step 5: Migration** (partition DB only):

```bash
set -a && source .env && set +a && mix ash.codegen add_file_processing_retry_state
TESTCMD mix ash.migrate
```

Inspect the generated migration: it must ONLY add the two columns to `files`. If codegen proposes anything else (there is known unrelated snapshot drift in this repo), revert the unrelated snapshot hunks and keep only this change, as was done on the OAuth branch.

- [ ] **Step 6: Run the tests, then `TESTCMD mix test test/magus/files test/magus/knowledge`.**

- [ ] **Step 7: Compile gate + commit** (include migration + resource snapshot):

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/files/ priv/repo/migrations priv/resource_snapshots \
  test/magus/files/file/process_file_chunks_test.exs config/test.exs
git commit -m "feat(files): bounded automatic retries for transient processing failures"
```

---

### Task 6: Sync-detected remote deletions hard-delete (chunks, storage, quota)

**Files:**
- Modify: `lib/magus/files/files.ex` (`define :destroy_file, action: :destroy`)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex` (add `delete_remote_gone_file/1`)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` (replace `soft_delete_file/1` uses, delete the helper)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Produces: `SyncHelpers.delete_remote_gone_file(file) :: :ok | :error`. Goes through the primary `:destroy` action, so `DeleteFile` removes chunks + storage object and `StorageTracking.track_destroy` reclaims quota. USER-initiated trash (`:soft_delete`) is untouched; only sync-detected remote deletions are hard.
- Per the Global Constraints: no retroactive purge of already-soft-deleted connector files.

- [ ] **Step 1: Failing test**:

```elixir
  describe "remote deletion hard-deletes local file, chunks, and storage" do
    test "fallback diff removes the row entirely and reclaims storage" do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "NC", provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}},
          actor: user
        )

      {:ok, _} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id, %{name: "F", external_id: "/f", external_path: "/f"}, actor: user)

      body = "bytes to reclaim"
      path = "test/#{Ash.UUIDv7.generate()}.txt"
      {:ok, _} = Magus.Files.Storage.store(path, body)

      {:ok, file} =
        Magus.Files.create_file_from_connector(
          %{name: "gone.txt", type: :text, mime_type: "text/plain",
            file_size: byte_size(body), file_path: path,
            knowledge_collection_id: collection.id, external_id: "remote-1",
            external_etag: "e1", external_updated_at: DateTime.utc_now()},
          actor: user
        )

      assert :ok =
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.delete_remote_gone_file(file)

      require Ash.Query

      # Hard gone: not even the trash (IncludeTrashed-style) sees it.
      assert {:error, _} = Magus.Files.get_file(file.id, authorize?: false)
      assert {:error, _} = Magus.Files.Storage.get(path)

      chunk_rows =
        Magus.Files.Chunk
        |> Ash.Query.filter(file_id == ^file.id)
        |> Ash.count!(authorize?: false)

      assert chunk_rows == 0
    end
  end
```

- [ ] **Step 2: Verify failure** (`delete_remote_gone_file/1` undefined).

- [ ] **Step 3: Implement**:
  - `lib/magus/files/files.ex`: add `define :destroy_file, action: :destroy` in the File block.
  - `sync_helpers.ex`:

```elixir
  @doc """
  Hard-delete a file whose remote counterpart disappeared.

  Sync deletions bypass the user trash on purpose (user decision 2026-07-09):
  the remote is the source of truth for connector files, and soft-deleted
  copies would hold chunks, storage bytes, and quota forever. User-initiated
  deletion still goes through `:soft_delete` and the trash.
  """
  def delete_remote_gone_file(file) do
    case Magus.Files.destroy_file(file, authorize?: false) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sync: failed to hard-delete file #{file.id}: #{inspect(reason)}")
        :error
    end
  end
```

  - `incremental_sync.ex`: replace both `soft_delete_file(file)` call sites (delta `:deleted` clause and the fallback diff loop) with `SyncHelpers.delete_remote_gone_file(file)`, delete the private `soft_delete_file/1`, and update the fallback log line "Removed N deleted files" to "Hard-deleted N remotely removed files".

- [ ] **Step 4: Run the test + the knowledge suite.** Existing tests asserting soft-delete behavior on sync deletions (grep for `soft_delete` / `deleted_at` in `test/magus/knowledge/`) must be updated to assert hard deletion; that is a spec change, not a regression.

- [ ] **Step 5: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/files/files.ex lib/magus/knowledge/knowledge_collection/changes/ \
  test/magus/knowledge/
git commit -m "feat(knowledge): sync-detected remote deletions hard-delete files, chunks, and storage"
```

---

### Task 7: Full sync updates changed files and removes remote-gone ones

**Files:**
- Modify: `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex:106-206` (`sync_all_items`, `do_paginate`, `process_items`)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Consumes: `SyncHelpers.update_existing_file/5` ({:ok, :updated} | {:ok, :unchanged}), `SyncHelpers.delete_remote_gone_file/1`.
- Produces: full sync becomes authoritative: creates new files, updates changed ones (list-time etag differs OR is nil, with the hash guard preventing wasted reprocessing), and hard-deletes local files absent from the complete remote listing. The deletion diff runs ONLY when pagination completed without error.

- [ ] **Step 1: Failing test** (fake-Drive full sync; extend the existing full-sync Bypass setup):

```elixir
  describe "full sync updates and deletes" do
    setup do
      drive = Bypass.open()
      prev = Application.get_env(:magus, :google_drive_base_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive.port}")
      on_exit(fn -> Application.put_env(:magus, :google_drive_base_url, prev) end)
      {:ok, drive: drive}
    end

    test "changed etag re-fetches; remote-gone file is removed", %{drive: drive} do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "GD", provider: :google_drive,
            auth_config: %{"access_token" => "tok", "refresh_token" => "rt"}},
          actor: user)

      {:ok, source} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id, %{name: "F", external_id: "root-folder", external_path: "/r"}, actor: user)

      # Pre-existing local files: one whose remote etag changed, one gone remotely.
      for {ext_id, name} <- [{"file-changed", "changed.txt"}, {"file-gone", "gone.txt"}] do
        path = "test/#{Ash.UUIDv7.generate()}.txt"
        {:ok, _} = Magus.Files.Storage.store(path, "old #{name}")

        {:ok, _} =
          Magus.Files.create_file_from_connector(
            %{name: name, type: :text, mime_type: "text/plain",
              file_size: 10, file_path: path,
              knowledge_collection_id: collection.id, external_id: ext_id,
              external_etag: "etag-old", external_updated_at: DateTime.utc_now(),
              metadata: %{"content_hash" => "stale-hash"}},
            actor: user)
      end

      Bypass.stub(drive, "GET", "/files", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        q = conn.query_params["q"] || ""

        body =
          if String.contains?(q, "mimeType='application/vnd.google-apps.folder'") do
            %{"files" => []}
          else
            %{"files" => [
              %{"id" => "file-changed", "name" => "changed.txt",
                "mimeType" => "text/plain",
                "modifiedTime" => "2026-07-09T12:00:00Z", "md5Checksum" => "etag-NEW"}
            ]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.stub(drive, "GET", "/files/file-changed", fn conn ->
        Plug.Conn.resp(conn, 200, "fresh content")
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.FullSync.do_full_sync(collection)

      require Ash.Query

      files =
        Magus.Files.File
        |> Ash.Query.filter(knowledge_collection_id == ^collection.id)
        |> Ash.read!(authorize?: false)

      by_ext = Map.new(files, &{&1.external_id, &1})

      assert Map.has_key?(by_ext, "file-changed")
      assert by_ext["file-changed"].external_etag == "etag-NEW"
      assert by_ext["file-changed"].status == :pending
      refute Map.has_key?(by_ext, "file-gone")
    end
  end
```

- [ ] **Step 2: Verify failure**: today `file-changed` keeps `etag-old` (dedup skips it) and `file-gone` survives.

- [ ] **Step 3: Implement in `full_sync.ex`**:
  - `get_existing_external_ids/1` becomes `get_existing_files/1` returning full records (mirror the incremental version; no select), and `sync_all_items/4` builds `existing_by_external_id = Map.new(existing, &{&1.external_id, &1})`.
  - Thread a `remote_ids` MapSet accumulator through `do_paginate/…` (append each page's item ids).
  - `process_items/…` existing-file branch: instead of counting and skipping, apply the same needs-check rule as fallback sync:

```elixir
      case Map.get(existing_by_external_id, item.id) do
        nil ->
          # unchanged: create path (create_file_from_item)
          ...

        file ->
          needs_check? = is_nil(item.etag) or file.external_etag != item.etag

          if needs_check? do
            case SyncHelpers.update_existing_file(conn, connector, file, item, actor) do
              {:ok, :updated} ->
                SyncLogger.info(cid, "Updated: #{item.name}")
                {item_count + 1, error_count, updated_max}

              {:ok, :unchanged} ->
                {item_count + 1, error_count, updated_max}

              {:error, reason} ->
                SyncLogger.error(cid, "Failed to update #{item.name}: #{inspect(reason)}")
                {item_count, error_count + 1, updated_max}
            end
          else
            {item_count + 1, error_count, updated_max}
          end
      end
```

  - After `do_paginate` returns `{:ok, ...}` (success only), diff and hard-delete:

```elixir
      gone =
        existing_by_external_id
        |> Enum.reject(fn {ext_id, _f} -> MapSet.member?(remote_ids, ext_id) end)

      Enum.each(gone, fn {_ext_id, file} -> SyncHelpers.delete_remote_gone_file(file) end)

      if gone != [] do
        SyncLogger.info(cid, "Hard-deleted #{length(gone)} remotely removed files")
      end
```

  Keep the signature churn contained: it is fine to introduce a small state struct or map for the paginate accumulator instead of adding two more positional args; choose whichever keeps `do_paginate` readable.

- [ ] **Step 4: Run the test + whole knowledge suite** (existing full-sync tests asserting "existing files are skipped" may need updating to the new update semantics; that is the point of the task).

- [ ] **Step 5: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/knowledge_collection/changes/full_sync.ex \
  test/magus/knowledge/knowledge_collection_test.exs
git commit -m "feat(knowledge): full sync updates changed files and removes remote-gone ones"
```

---

### Task 8: Notion delete reconciliation via `deletes_in_delta?/0`

**Files:**
- Modify: `lib/magus/knowledge/connector.ex` (optional callback)
- Modify: `lib/magus/knowledge/connectors/google_drive.ex` (returns true)
- Modify: `lib/magus/knowledge/connectors/notion.ex` (configurable base URL: test seam, mirrors the Drive `base_url/0` pattern)
- Modify: `config/test.exs` (notion base URL default)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` (`delta_sync` runs reconciliation when the connector's delta carries no delete signal)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`

**Interfaces:**
- Produces: `@callback deletes_in_delta?() :: boolean()` with `@optional_callbacks deletes_in_delta?: 0` on `Magus.Knowledge.Connector`. Semantics: "my detect_changes emits `:deleted` changes". Absent or false means the delta path cannot see deletions, so `delta_sync` runs a full-listing diff after applying changes and hard-deletes local files missing remotely.
- Google Drive: `def deletes_in_delta?, do: true` (its Changes API emits removals). Notion: no callback (databases' `last_edited_time` query has no tombstones).

- [ ] **Step 1: Make the Notion base URL configurable.** In `lib/magus/knowledge/connectors/notion.ex`, find the hardcoded `https://api.notion.com` base (module attribute or inline) and convert to the Drive pattern:

```elixir
  @default_base_url "https://api.notion.com/v1"

  defp base_url, do: Application.get_env(:magus, :notion_base_url, @default_base_url)
```

(match the exact existing default including the `/v1` suffix as found in the file). Add the default to `config/test.exs`. Update all request-building call sites to `base_url()`.

- [ ] **Step 2: Write the failing test** (Bypass fake Notion database):

```elixir
  describe "notion delta reconciles deletions" do
    setup do
      notion = Bypass.open()
      prev = Application.get_env(:magus, :notion_base_url)
      Application.put_env(:magus, :notion_base_url, "http://localhost:#{notion.port}/v1")
      on_exit(fn -> Application.put_env(:magus, :notion_base_url, prev) end)
      {:ok, notion: notion}
    end

    test "a page missing from the full listing is hard-deleted", %{notion: notion} do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "N", provider: :notion, auth_config: %{"access_token" => "secret"}},
          actor: user
        )

      {:ok, _} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      # A database collection (detect_changes supported). Check
      # notion.ex page_collection?/1 for how database vs page collections are
      # distinguished (likely a settings flag or external_id shape) and build
      # the collection accordingly so detect_changes does NOT return
      # :not_supported.
      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "DB", external_id: "db-1", external_path: "/db-1",
            settings: %{"collection_type" => "database"}},
          actor: user
        )

      {:ok, collection} =
        Magus.Knowledge.update_sync_status(
          collection,
          %{sync_status: :synced,
            last_synced_at: DateTime.add(DateTime.utc_now(), -7200, :second)},
          authorize?: false
        )

      # Local file whose Notion page no longer exists.
      path = "test/#{Ash.UUIDv7.generate()}.md"
      {:ok, _} = Magus.Files.Storage.store(path, "old page")

      {:ok, gone_file} =
        Magus.Files.create_file_from_connector(
          %{name: "gone.md", type: :text, mime_type: "text/markdown",
            file_size: 8, file_path: path,
            knowledge_collection_id: collection.id, external_id: "page-gone",
            external_etag: "t1", external_updated_at: DateTime.utc_now()},
          actor: user
        )

      # Delta: no edits since last sync. Full listing: empty database.
      Bypass.stub(notion, "POST", "/v1/databases/db-1/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "has_more" => false, "next_cursor" => nil}))
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.IncrementalSync.do_incremental_sync(collection)

      assert {:error, _} = Magus.Files.get_file(gone_file.id, authorize?: false)
    end
  end
```

Adjust the collection fixture and the Bypass route to whatever `notion.ex` actually uses for database listing (`list_items` for database collections also POSTs `/databases/:id/query`; one stub can serve both delta and listing since both return the empty result here). Read `notion.ex` `page_collection?/1` and `list_items/3` first and fix the fixture so the database path is taken.

- [ ] **Step 3: Verify failure**: the file survives (no delete signal, no reconciliation).

- [ ] **Step 4: Implement**:
  - `connector.ex`: add after the `update_item` callback:

```elixir
  @doc """
  Whether `detect_changes/3` emits `:deleted` changes.

  Connectors whose delta feed has no deletion signal (for example Notion
  database queries filtered by last_edited_time) return false or omit the
  callback; the sync framework then reconciles deletions with a full-listing
  diff after applying delta changes.
  """
  @callback deletes_in_delta?() :: boolean()

  @optional_callbacks deletes_in_delta?: 0
```

  - `google_drive.ex`: add near the other `@impl true` callbacks:

```elixir
  @impl true
  def deletes_in_delta?, do: true
```

  - `incremental_sync.ex` `delta_sync/7`: after the change-processing reduce and BEFORE computing the completion attrs:

```elixir
    reconciliation_errors =
      if deletes_in_delta?(connector) do
        0
      else
        reconcile_remote_deletions(conn, connector, collection, existing_by_external_id)
      end
```

with helpers:

```elixir
  defp deletes_in_delta?(connector) do
    Code.ensure_loaded?(connector) and
      function_exported?(connector, :deletes_in_delta?, 0) and
      connector.deletes_in_delta?()
  end

  # Full-listing diff for connectors whose delta cannot see deletions.
  # Returns the number of failures (0 on clean run or on listing failure,
  # which is logged and skipped rather than failing the whole sync).
  defp reconcile_remote_deletions(conn, connector, collection, existing_by_external_id) do
    case list_all_remote_items(conn, connector, collection) do
      {:ok, remote_items} ->
        remote_ids = MapSet.new(remote_items, & &1.id)

        existing_by_external_id
        |> Enum.reject(fn {ext_id, _f} -> MapSet.member?(remote_ids, ext_id) end)
        |> Enum.reduce(0, fn {_ext_id, file}, failures ->
          case SyncHelpers.delete_remote_gone_file(file) do
            :ok -> failures
            :error -> failures + 1
          end
        end)

      {:error, reason} ->
        SyncLogger.warn(
          collection.id,
          "Deletion reconciliation skipped (listing failed): #{inspect(reason)}"
        )

        0
    end
  end
```

Add `reconciliation_errors` into the completion `error_count` sum.

- [ ] **Step 5: Run the test + knowledge suite + notion connector tests** (the base_url change touches every Notion request; `test/magus/knowledge/connectors/notion_test.exs` must stay green).

- [ ] **Step 6: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/connector.ex lib/magus/knowledge/connectors/ \
  lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex \
  config/test.exs test/magus/knowledge/
git commit -m "feat(knowledge): reconcile deletions for connectors whose delta has no delete signal"
```

---

### Task 9: Watchdog, scheduling guard, and sync hygiene bundle

Small related fixes, one commit.

**Files:**
- Modify: `lib/magus/knowledge/knowledge_collection.ex` (watchdog trigger + action + incremental `where` guard)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/full_sync.ex` (completion/error attrs)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/incremental_sync.ex` (completion attrs, content_updated_at)
- Modify: `lib/magus/knowledge/knowledge_collection/changes/sync_helpers.ex` (`format_sync_error(:rate_limited)`)
- Modify: `lib/magus/knowledge/connectors/notion.ex` and `nextcloud.ex` (Retry-After cap)
- Modify: `lib/magus/knowledge/connect.ex` (drop affine)
- Test: `test/magus/knowledge/knowledge_collection_test.exs`, `test/magus/knowledge/connect_test.exs`

**Interfaces / spec, item by item:**

1. **Stuck-sync watchdog.** New update action + trigger on `KnowledgeCollection`:

```elixir
    update :mark_sync_interrupted do
      require_atomic? false
      change set_attribute(:sync_status, :error)
      change set_attribute(:last_error, "Sync appeared stuck for over 2 hours and was reset. It will be retried on the next scheduled run.")
    end
```

```elixir
      trigger :recover_stuck_sync do
        action :mark_sync_interrupted
        queue :knowledge_sync
        scheduler_cron "*/30 * * * *"
        where expr(sync_status == :syncing and updated_at < ago(2, :hour))
        worker_module_name __MODULE__.Workers.RecoverStuckSync
        scheduler_module_name __MODULE__.Schedulers.RecoverStuckSync
      end
```

   `SyncRecovery` (boot-time) stays; the trigger covers the long-running-node case. A legitimately long full sync (over 2h) may be flapped to `:error` and later overwritten by its own completion write; acceptable and documented in the action description.

2. **Cross-trigger guard.** The `incremental_sync` trigger `where` gains `and sync_status != :syncing` so the hourly cron does not stack onto a running full sync (the watchdog above prevents a stuck `:syncing` from starving incremental forever). Full expression:

```elixir
        where expr(
                sync_status != :pending and sync_status != :syncing and
                  sync_strategy != :manual and
                  knowledge_source.needs_reauth == false
              )
```

3. **Partial-failure surfacing.** In all three successful-completion sites (full_sync `do_full_sync`, incremental `delta_sync`, incremental `fallback_sync`), replace `last_error: nil` with:

```elixir
        last_error:
          if(error_count > 0,
            do: "#{error_count} item(s) failed during the last sync. See the sync log.",
            else: nil
          )
```

4. **error_count purity.** `error_count` means "items that failed in the last run" only. Remove `error_count: (collection.error_count || 0) + 1` from `full_sync.ex`'s error branch and from `incremental_sync.ex`'s `update_sync_error/2` (keep `sync_status: :error` and `last_error`).

5. **Rate-limit message.** Add to `SyncHelpers`:

```elixir
  def format_sync_error(:rate_limited),
    do: "Rate limited by the provider. The next scheduled sync will retry automatically."
```

alongside the existing `format_sync_error/1` clauses (`:reauth_required` clause exists; keep the `inspect/1` catch-all LAST). Use `SyncHelpers.format_sync_error(reason)` for `last_error` in full_sync's error branch and incremental's `update_sync_error/2` instead of raw `inspect(reason)`.

6. **Retry-After cap.** In `notion.ex` `maybe_retry` and `nextcloud.ex`'s equivalent, cap the sleep: `retry_after = min(retry_after_seconds(response), 15)`. Rationale comment: the sleep occupies one of only 5 global knowledge_sync queue slots.

7. **content_updated_at symmetry.** Incremental completions set `content_updated_at: now` when the run created, updated, or deleted anything (delta: `changes != []`; fallback: created + updated + deleted > 0). Add to the respective `sync_attrs`.

8. **AFFiNE removal.** `connect.ex`: `@providers ~w(google_drive notion nextcloud web)`, delete the `defp default_name(:affine)` clause. The SPA wizard already lists only the four remaining providers; classic LiveView is out of scope. Keep `Connector.connector_for(:affine)` so any legacy source errors gracefully instead of raising.

- [ ] **Step 1: Failing tests** (three focused ones):

```elixir
  # knowledge_collection_test.exs
  describe "sync hygiene" do
    test "watchdog action resets a stuck syncing collection" do
      user = generate(user())

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "NC", provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}},
          actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id, %{name: "F", external_id: "/f", external_path: "/f"}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.update_sync_status(collection, %{sync_status: :syncing}, authorize?: false)

      {:ok, reset} = Ash.update(collection, %{}, action: :mark_sync_interrupted, authorize?: false)
      assert reset.sync_status == :error
      assert reset.last_error =~ "stuck"
    end

    test "scheduler filter excludes :syncing collections" do
      # mirror of the trigger where clause; keep in sync with knowledge_collection.ex
      user = generate(user())

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "NC", provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}},
          actor: user)

      {:ok, _} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, syncing} =
        Magus.Knowledge.create_collection(
          source.id, %{name: "A", external_id: "/a", external_path: "/a"}, actor: user)

      {:ok, syncing} =
        Magus.Knowledge.update_sync_status(syncing, %{sync_status: :syncing}, authorize?: false)

      require Ash.Query

      ids =
        Magus.Knowledge.KnowledgeCollection
        |> Ash.Query.filter(
          sync_status != :pending and sync_status != :syncing and
            sync_strategy != :manual and knowledge_source.needs_reauth == false
        )
        |> Ash.read!(authorize?: false)
        |> MapSet.new(& &1.id)

      refute MapSet.member?(ids, syncing.id)
    end
  end
```

```elixir
  # connect_test.exs
    test "affine is no longer a connectable provider" do
      user = generate(user())
      refute "affine" in Magus.Knowledge.Connect.providers()
      assert {:error, "Unknown provider"} = Connect.connect_and_create("affine", %{}, actor: user)
    end
```

- [ ] **Step 2: Verify failures, implement all eight items, re-run.**

- [ ] **Step 3: Run the full knowledge suite plus connectors** (`TESTCMD mix test test/magus/knowledge`).

- [ ] **Step 4: Compile gate + commit**

```bash
TESTCMD mix compile --warnings-as-errors
git add lib/magus/knowledge/ test/magus/knowledge/
git commit -m "feat(knowledge): stuck-sync watchdog, scheduling guard, and sync hygiene fixes"
```

---

### Task 10: Full regression pass

**Files:** none (verification only).

- [ ] **Step 1**: `TESTCMD mix test test/magus/knowledge test/magus/files test/magus_web/rpc` all green.
- [ ] **Step 2**: `TESTCMD mix compile --warnings-as-errors` clean.
- [ ] **Step 3**: `mix format` then `git diff --stat`; commit any formatting as `chore: mix format`.
- [ ] **Step 4**: `TESTCMD mix test` (whole suite minus excluded tags) as the final gate; investigate anything red before declaring done.

---

## Self-Review Notes

- **Finding coverage:** P0-1 Drive drop → Task 2. P0-2 chunk duplication → Task 4. P0-3 web re-process loop → Tasks 1+3 (hash guard + lastmod etag). P1-4 Notion deletes → Task 8. P1-5 full sync updates/deletes → Task 7. P1-6 processing retries + reprocess → Task 5. P1-7 watchdog → Task 9.1. P1-8 reclamation → Task 6 (immediate hard delete per user decision; no retroactive purge, rationale in Global Constraints). P1-9 quota-on-update + partial-failure surfacing → Task 1 (quota) + Task 9.3. P2 race guard → Task 9.2. P2 rate-limit asymmetry/message → Task 9.5. P2 Retry-After sleeps → Task 9.6. P2 error_count semantics → Task 9.4. P2 content_updated_at → Task 9.7. P2 AFFiNE → Task 9.8. Deliberately NOT addressed: per-API-call rate limiting (bigger change, current per-run gate stays), plan-less users getting 0 B limits (product question, out of scope).
- **Type consistency:** `update_existing_file/5` returns `{:ok, :updated} | {:ok, :unchanged} | {:error, term}` and every caller (Tasks 1, 2, 7) matches those shapes. `delete_remote_gone_file/1` returns `:ok | :error` and callers (Tasks 6, 7, 8) treat `:error` as an item error count. `content_hash/1` is used by Tasks 1, 4 tests, and full_sync create.
- **Ordering:** Task 1 is the foundation (Tasks 2, 3, 6, 7, 8 build on its helpers and semantics). Tasks 4-5 are independent (Files domain). Task 9 last before regression because it touches completion attrs that earlier tasks' tests assert.
- **Known risks for implementers:** (a) existing tests may assert the OLD semantics (soft delete on sync deletion, full-sync skip-existing, `last_error: nil` with item errors); updating those assertions is part of the respective task, not scope creep. (b) `ago/2` in the AshOban `where` expression: if the expression fails to compile, use `expr(sync_status == :syncing and updated_at < ago(2, :hour))` exactly; `ago` is a documented Ash expression. (c) codegen may surface unrelated snapshot drift; keep only this plan's changes in committed migrations/snapshots.
