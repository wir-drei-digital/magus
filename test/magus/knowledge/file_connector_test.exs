defmodule Magus.Knowledge.FileConnectorTest do
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Knowledge
  alias Magus.Files

  defp create_collection(user) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "Test", provider: :notion, auth_config: %{"key" => "test"}},
        actor: user
      )

    {:ok, collection} =
      Knowledge.create_collection(
        source.id,
        %{name: "Docs", external_id: "ext_1", external_path: "/docs"},
        actor: user
      )

    collection
  end

  defp setup_user_with_plan do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _sub} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    user
  end

  describe "create_from_connector" do
    test "creates a file with connector source and external metadata" do
      user = setup_user_with_plan()
      collection = create_collection(user)

      {:ok, file} =
        Files.create_file_from_connector(
          %{
            name: "design-doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 12345,
            file_path: "test/path/design-doc.pdf",
            knowledge_collection_id: collection.id,
            external_id: "notion_page_abc123",
            external_etag: "etag_v1",
            external_updated_at: DateTime.utc_now(),
            external_url: "https://notion.so/page/abc123"
          },
          actor: user
        )

      assert file.source == :connector
      assert file.status == :pending
      assert file.knowledge_collection_id == collection.id
      assert file.external_id == "notion_page_abc123"
      assert file.external_etag == "etag_v1"
      assert file.external_url == "https://notion.so/page/abc123"
    end

    test "enqueues ProcessFile job" do
      user = setup_user_with_plan()
      collection = create_collection(user)

      {:ok, _file} =
        Files.create_file_from_connector(
          %{
            name: "test.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 100,
            file_path: "test/path/test.txt",
            knowledge_collection_id: collection.id,
            external_id: "ext_file_1",
            external_etag: "v1"
          },
          actor: user
        )

      assert_enqueued(worker: Magus.Files.File.Workers.ProcessFile)
    end

    test "prevents duplicate files in same collection" do
      user = setup_user_with_plan()
      collection = create_collection(user)

      attrs = %{
        name: "test.txt",
        type: :text,
        mime_type: "text/plain",
        file_size: 100,
        file_path: "test/path/test.txt",
        knowledge_collection_id: collection.id,
        external_id: "same_ext_id",
        external_etag: "v1"
      }

      {:ok, _} = Files.create_file_from_connector(attrs, actor: user)
      assert {:error, _} = Files.create_file_from_connector(attrs, actor: user)
    end
  end

  describe "soft delete" do
    test "soft_delete sets deleted_at without destroying file" do
      user = setup_user_with_plan()
      collection = create_collection(user)

      {:ok, file} =
        Files.create_file_from_connector(
          %{
            name: "to-delete.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 100,
            file_path: "test/path/to-delete.txt",
            knowledge_collection_id: collection.id,
            external_id: "del_1",
            external_etag: "v1"
          },
          actor: user
        )

      {:ok, deleted} = Files.soft_delete_file(file, authorize?: false)
      assert not is_nil(deleted.deleted_at)
    end
  end
end
