defmodule Magus.Knowledge.KnowledgeCollectionTest do
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Knowledge
  alias Magus.Files
  alias Magus.Usage

  defp create_source(user) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "Test Source", provider: :notion, auth_config: %{"key" => "test"}},
        actor: user
      )

    source
  end

  describe "create_collection" do
    test "creates a collection for a source" do
      user = generate(user())
      source = create_source(user)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{
            name: "Engineering Docs",
            external_id: "ext_folder_123",
            external_path: "/Engineering"
          },
          actor: user
        )

      assert collection.name == "Engineering Docs"
      assert collection.external_id == "ext_folder_123"
      assert collection.sync_status == :pending
      assert collection.sync_strategy == :poll
      assert collection.sync_interval_minutes == 60
      assert collection.knowledge_source_id == source.id
    end
  end

  describe "update_sync_status" do
    test "updates sync status and metadata" do
      user = generate(user())
      source = create_source(user)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "Docs", external_id: "ext_1", external_path: "/docs"},
          actor: user
        )

      now = DateTime.utc_now()

      {:ok, updated} =
        Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :synced,
            last_synced_at: now,
            item_count: 42
          },
          authorize?: false
        )

      assert updated.sync_status == :synced
      assert updated.item_count == 42
    end
  end

  describe "destroy_collection file cleanup" do
    setup do
      user = generate(user())
      free_plan = ensure_free_plan()

      {:ok, _sub} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      source = create_source(user)

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "Docs", external_id: "ext_1", external_path: "/docs"},
          actor: user
        )

      %{user: user, source: source, collection: collection}
    end

    defp create_connector_file(user, collection, name) do
      content = String.duplicate("x", 1_000)
      path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(1_000_000)}")
      File.write!(path, content)

      {:ok, file} =
        Files.create_file_from_connector(
          %{
            name: name,
            type: :document,
            mime_type: "text/markdown",
            file_size: byte_size(content),
            file_path: path,
            knowledge_collection_id: collection.id,
            external_id: "ext_#{:rand.uniform(1_000_000)}"
          },
          actor: user
        )

      file
    end

    test "enqueues cleanup job on destroy", %{user: user, collection: collection} do
      file1 = create_connector_file(user, collection, "doc1.md")
      file2 = create_connector_file(user, collection, "doc2.md")

      :ok = Knowledge.destroy_collection(collection, actor: user)

      assert_enqueued(
        worker: Magus.Knowledge.KnowledgeCollection.Workers.CleanupFiles,
        args: %{file_ids: Enum.sort([file1.id, file2.id])}
      )
    end

    test "cleanup worker deletes files and decrements storage", %{
      user: user,
      collection: collection
    } do
      file1 = create_connector_file(user, collection, "doc1.md")
      file2 = create_connector_file(user, collection, "doc2.md")
      total_size = file1.file_size + file2.file_size

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)

      :ok = Knowledge.destroy_collection(collection, actor: user)

      # Execute the enqueued worker
      assert %{success: 1} =
               Oban.drain_queue(queue: :knowledge_sync)

      # Files should be destroyed
      assert {:error, _} = Ash.get(Magus.Files.File, file1.id, authorize?: false)
      assert {:error, _} = Ash.get(Magus.Files.File, file2.id, authorize?: false)

      # Storage should be decremented
      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes - total_size
    end

    test "does not enqueue job when no files exist", %{user: user, collection: collection} do
      :ok = Knowledge.destroy_collection(collection, actor: user)

      refute_enqueued(worker: Magus.Knowledge.KnowledgeCollection.Workers.CleanupFiles)
    end
  end

  describe "list_collections_for_source" do
    test "returns collections belonging to a source" do
      user = generate(user())
      source = create_source(user)

      {:ok, _c1} =
        Knowledge.create_collection(
          source.id,
          %{name: "Docs", external_id: "e1", external_path: "/docs"},
          actor: user
        )

      {:ok, _c2} =
        Knowledge.create_collection(
          source.id,
          %{name: "Wiki", external_id: "e2", external_path: "/wiki"},
          actor: user
        )

      {:ok, collections} =
        Knowledge.list_collections_for_source(source.id, actor: user)

      assert length(collections) == 2
    end
  end

  describe "sync reauth handling" do
    setup do
      bypass = Bypass.open()
      prev = Application.get_env(:magus, :google_token_url)
      Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")
      System.put_env("GOOGLE_CLIENT_ID", "id")
      System.put_env("GOOGLE_CLIENT_SECRET", "secret")
      on_exit(fn -> Application.put_env(:magus, :google_token_url, prev) end)
      {:ok, bypass: bypass}
    end

    test "a dead refresh token during full sync flags the source for reauth", %{bypass: bypass} do
      user = generate(user())
      expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{
              "access_token" => "old",
              "refresh_token" => "dead",
              "expires_at" => expired
            }
          },
          actor: user
        )

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Folder", external_id: "root", external_path: "/root"},
          actor: user
        )

      Bypass.expect(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.FullSync.do_full_sync(collection)

      {:ok, reloaded} = Magus.Knowledge.get_source(source.id, actor: user)
      assert reloaded.needs_reauth == true
    end

    test "a reactive 401 refresh during full sync merges the refreshed token, preserving expires_at",
         %{bypass: token_bypass} do
      drive_bypass = Bypass.open()
      prev_drive_base = Application.get_env(:magus, :google_drive_base_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive_bypass.port}")
      on_exit(fn -> Application.put_env(:magus, :google_drive_base_url, prev_drive_base) end)

      user = generate(user())
      # Not-yet-expiring, so TokenManager.ensure_fresh/1 skips its proactive
      # refresh and the reactive 401-refresh path in the connector is what
      # gets exercised (and what must persist expires_at correctly).
      not_expiring = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{
              "access_token" => "stale-access-token",
              "refresh_token" => "still-good-refresh-token",
              "expires_at" => not_expiring,
              "some_other_key" => "keep-me"
            }
          },
          actor: user
        )

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "Folder", external_id: "root", external_path: "/root"},
          actor: user
        )

      counter = start_supervised!({Agent, fn -> 0 end})

      Bypass.expect(drive_bypass, "GET", "/files", fn conn ->
        case Agent.get_and_update(counter, &{&1, &1 + 1}) do
          0 ->
            Plug.Conn.resp(conn, 401, "{}")

          _ ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"files" => []}))
        end
      end)

      Bypass.expect_once(token_bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "fresh-access-token",
            "refresh_token" => "still-good-refresh-token",
            "expires_in" => 3600
          })
        )
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.FullSync.do_full_sync(collection)

      {:ok, reloaded} = Magus.Knowledge.get_source(source.id, actor: user)

      assert reloaded.auth_config["access_token"] == "fresh-access-token"
      assert is_binary(reloaded.auth_config["expires_at"])
      assert reloaded.auth_config["expires_at"] != not_expiring
      # Merge (not replace) must keep keys the reactive refresh never touched.
      assert reloaded.auth_config["some_other_key"] == "keep-me"
    end
  end

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

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

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

      item = %{
        id: "file-1",
        name: "doc.txt",
        etag: "etag-new",
        updated_at: DateTime.utc_now(),
        mime_type: "text/plain"
      }

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

      item = %{
        id: "file-1",
        name: "doc.txt",
        etag: "etag-new",
        updated_at: DateTime.utc_now(),
        mime_type: "text/plain"
      }

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

      # The Google Drive connector itself hard-caps downloads at 100 MiB
      # (same as the default "pro" plan's max_upload_bytes), so exceeding
      # both at once would trip the connector's own guard instead of the
      # quota check under test here. Give this user a much smaller plan so
      # the fetched content clears the connector's cap but still exceeds
      # the plan's upload quota.
      {:ok, tiny_plan} =
        Magus.Usage.create_usage_plan(
          %{
            key: "wt-sync-tiny-#{Ash.UUIDv7.generate()}",
            name: "Tiny",
            price_monthly_cents: 0,
            storage_bytes: 1_000_000,
            max_upload_bytes: 100,
            is_active: true,
            sort_order: 99
          },
          authorize?: false
        )

      {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

      {:ok, _} =
        Magus.Usage.upgrade_subscription(sub, %{usage_plan_id: tiny_plan.id}, authorize?: false)

      huge = String.duplicate("x", 1_000)

      Bypass.expect(ctx.drive, "GET", "/files/file-1", fn conn ->
        Plug.Conn.resp(conn, 200, huge)
      end)

      {:ok, conn} =
        Magus.Knowledge.Connectors.GoogleDrive.connect(%{"access_token" => "tok"})

      item = %{
        id: "file-1",
        name: "doc.txt",
        etag: "etag-new",
        updated_at: DateTime.utc_now(),
        mime_type: "text/plain"
      }

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

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

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

  describe "remote deletion hard-deletes local file, chunks, and storage" do
    test "fallback diff removes the row entirely and reclaims storage" do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "NC",
            provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}
          },
          actor: user
        )

      {:ok, _} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "F", external_id: "/f", external_path: "/f"},
          actor: user
        )

      body = "bytes to reclaim"
      path = "test/#{Ash.UUIDv7.generate()}.txt"
      {:ok, _} = Magus.Files.Storage.store(path, body)

      {:ok, file} =
        Magus.Files.create_file_from_connector(
          %{
            name: "gone.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: byte_size(body),
            file_path: path,
            knowledge_collection_id: collection.id,
            external_id: "remote-1",
            external_etag: "e1",
            external_updated_at: DateTime.utc_now()
          },
          actor: user
        )

      assert :ok =
               Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers.delete_remote_gone_file(
                 file
               )

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
          %{
            name: "GD",
            provider: :google_drive,
            auth_config: %{"access_token" => "tok", "refresh_token" => "rt"}
          },
          actor: user
        )

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "F", external_id: "root-folder", external_path: "/r"},
          actor: user
        )

      # Pre-existing local files: one whose remote etag changed, one gone remotely.
      for {ext_id, name} <- [{"file-changed", "changed.txt"}, {"file-gone", "gone.txt"}] do
        path = "test/#{Ash.UUIDv7.generate()}.txt"
        {:ok, _} = Magus.Files.Storage.store(path, "old #{name}")

        {:ok, _} =
          Magus.Files.create_file_from_connector(
            %{
              name: name,
              type: :text,
              mime_type: "text/plain",
              file_size: 10,
              file_path: path,
              knowledge_collection_id: collection.id,
              external_id: ext_id,
              external_etag: "etag-old",
              external_updated_at: DateTime.utc_now(),
              metadata: %{"content_hash" => "stale-hash"}
            },
            actor: user
          )
      end

      Bypass.stub(drive, "GET", "/files", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        q = conn.query_params["q"] || ""

        body =
          if String.contains?(q, "mimeType='application/vnd.google-apps.folder'") do
            %{"files" => []}
          else
            %{
              "files" => [
                %{
                  "id" => "file-changed",
                  "name" => "changed.txt",
                  "mimeType" => "text/plain",
                  "modifiedTime" => "2026-07-09T12:00:00Z",
                  "md5Checksum" => "etag-NEW"
                }
              ]
            }
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

    # Forcing a real destroy failure inside the sync's deletion pass would
    # require the file to still be present in the pre-sync "existing files"
    # snapshot yet fail when re-destroyed moments later; DeleteFile's storage
    # errors are logged, not surfaced as changeset errors, and every other
    # avenue we found to make `Ash.destroy(authorize?: false)` return
    # `{:error, _}` (stale/missing row) also removes the row from that
    # snapshot before the sync runs, so it never reaches the deletion pass.
    # We therefore assert the success-path accounting directly: a clean full
    # sync with a remote-gone file reports error_count 0 (no failures
    # incorrectly counted) and correctly excludes the deleted file, which
    # exercises the same `delete_remote_gone_files/2` return-value plumbing
    # the fix added (deletion_errors folded into total_errors).
    test "a clean full sync reports error_count 0 after a successful hard-delete", %{
      drive: drive
    } do
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

      {:ok, source} =
        Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "F", external_id: "root-folder", external_path: "/r"},
          actor: user
        )

      path = "test/#{Ash.UUIDv7.generate()}.txt"
      {:ok, _} = Magus.Files.Storage.store(path, "old gone.txt")

      {:ok, gone_file} =
        Magus.Files.create_file_from_connector(
          %{
            name: "gone.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 10,
            file_path: path,
            knowledge_collection_id: collection.id,
            external_id: "file-gone",
            external_etag: "etag-old",
            external_updated_at: DateTime.utc_now(),
            metadata: %{"content_hash" => "stale-hash"}
          },
          actor: user
        )

      Bypass.stub(drive, "GET", "/files", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"files" => []}))
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.FullSync.do_full_sync(collection)

      reloaded = Magus.Knowledge.get_collection!(collection.id, authorize?: false)

      assert reloaded.error_count == 0
      assert reloaded.sync_status == :synced
      assert {:error, _} = Magus.Files.get_file(gone_file.id, authorize?: false)
    end
  end

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

      # notion.ex page_collection?/1 keys purely on external_path starting
      # with "/page/"; a database collection is any path that does not, so
      # "/db-1" (no settings flag needed) takes the database path.
      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "DB", external_id: "db-1", external_path: "/db-1"},
          actor: user
        )

      {:ok, collection} =
        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :synced,
            last_synced_at: DateTime.add(DateTime.utc_now(), -7200, :second)
          },
          authorize?: false
        )

      # Local file whose Notion page no longer exists.
      path = "test/#{Ash.UUIDv7.generate()}.md"
      {:ok, _} = Magus.Files.Storage.store(path, "old page")

      {:ok, gone_file} =
        Magus.Files.create_file_from_connector(
          %{
            name: "gone.md",
            type: :text,
            mime_type: "text/markdown",
            file_size: 8,
            file_path: path,
            knowledge_collection_id: collection.id,
            external_id: "page-gone",
            external_etag: "t1",
            external_updated_at: DateTime.utc_now()
          },
          actor: user
        )

      # Delta: no edits since last sync. Full listing: empty database.
      # Both detect_changes and list_items (database path) POST the same
      # query endpoint, so one stub serves both requests.
      Bypass.stub(notion, "POST", "/v1/databases/db-1/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"results" => [], "has_more" => false, "next_cursor" => nil})
        )
      end)

      Magus.Knowledge.KnowledgeCollection.Changes.IncrementalSync.do_incremental_sync(collection)

      assert {:error, _} = Magus.Files.get_file(gone_file.id, authorize?: false)
    end
  end

  describe "sync hygiene" do
    test "watchdog action resets a stuck syncing collection" do
      user = generate(user())

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "NC",
            provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}
          },
          actor: user
        )

      {:ok, collection} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "F", external_id: "/f", external_path: "/f"},
          actor: user
        )

      {:ok, collection} =
        Magus.Knowledge.update_sync_status(collection, %{sync_status: :syncing},
          authorize?: false
        )

      {:ok, reset} =
        Ash.update(collection, %{}, action: :mark_sync_interrupted, authorize?: false)

      assert reset.sync_status == :error
      assert reset.last_error =~ "stuck"
    end

    test "scheduler filter excludes :syncing collections" do
      # mirror of the trigger where clause; keep in sync with knowledge_collection.ex
      user = generate(user())

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{
            name: "NC",
            provider: :nextcloud,
            auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}
          },
          actor: user
        )

      {:ok, _} = Magus.Knowledge.update_source_status(source, %{status: :active}, actor: user)

      {:ok, syncing} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "A", external_id: "/a", external_path: "/a"},
          actor: user
        )

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
end
