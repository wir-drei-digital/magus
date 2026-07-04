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
  end
end
