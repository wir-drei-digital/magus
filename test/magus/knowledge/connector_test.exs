defmodule Magus.Knowledge.ConnectorTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connector

  # A minimal mock connector that satisfies all callbacks.
  defmodule MockConnector do
    @behaviour Magus.Knowledge.Connector

    @impl true
    def connect(%{api_key: key}) when is_binary(key), do: {:ok, %{token: key}}
    def connect(_), do: {:error, :bad_credentials}

    @impl true
    def list_folders(%{token: _}, nil), do: {:ok, [%{id: "root", name: "Root", path: "/"}]}

    def list_folders(%{token: _}, path) when is_binary(path),
      do: {:ok, [%{id: "sub", name: "Sub", path: path <> "/sub"}]}

    def list_folders(_, _), do: {:error, :invalid_connection}

    @impl true
    def list_items(%{token: _}, _collection, nil) do
      item = %{
        id: "item-1",
        name: "doc.md",
        etag: "abc123",
        updated_at: ~U[2026-01-01 00:00:00Z],
        mime_type: "text/markdown"
      }

      {:ok, [item], %{next: "page2"}}
    end

    def list_items(%{token: _}, _collection, %{next: "page2"}) do
      item = %{
        id: "item-2",
        name: "other.md",
        etag: "def456",
        updated_at: ~U[2026-01-02 00:00:00Z],
        mime_type: "text/markdown"
      }

      {:ok, [item], nil}
    end

    def list_items(_, _, _), do: {:error, :invalid_connection}

    @impl true
    def fetch_content(%{token: _}, %{id: id}) do
      {:ok, "# Content for #{id}", %{word_count: 3}}
    end

    def fetch_content(_, _), do: {:error, :invalid_connection}

    @impl true
    def detect_changes(%{token: _}, _collection, %DateTime{} = _since) do
      change = %{
        type: :updated,
        item: %{
          id: "item-1",
          name: "doc.md",
          etag: "xyz789",
          updated_at: ~U[2026-02-01 00:00:00Z],
          mime_type: "text/markdown"
        }
      }

      {:ok, [change]}
    end

    def detect_changes(_, _, _), do: {:error, :invalid_connection}

    @impl true
    def register_webhook(%{token: _}, _collection, callback_url) when is_binary(callback_url) do
      {:ok, "webhook-#{:erlang.phash2(callback_url)}"}
    end

    def register_webhook(_, _, _), do: {:error, :not_supported}

    @impl true
    def create_item(%{token: _}, _collection, name, content, metadata)
        when is_binary(name) and is_binary(content) and is_map(metadata) do
      item = %{
        id: "new-item",
        name: name,
        etag: "new123",
        updated_at: DateTime.utc_now(),
        mime_type: Map.get(metadata, :mime_type, "application/octet-stream")
      }

      {:ok, item}
    end

    def create_item(_, _, _, _, _), do: {:error, :not_supported}

    @impl true
    def update_item(%{token: _}, _collection, external_id, content, metadata)
        when is_binary(external_id) and is_binary(content) and is_map(metadata) do
      item = %{
        id: external_id,
        name: Map.get(metadata, :name, "updated"),
        etag: "upd123",
        updated_at: DateTime.utc_now(),
        mime_type: Map.get(metadata, :mime_type, "application/octet-stream")
      }

      {:ok, item}
    end

    def update_item(_, _, _, _, _), do: {:error, :not_supported}
  end

  describe "connector_for/1" do
    test "returns the GoogleDrive module for :google_drive" do
      assert Connector.connector_for(:google_drive) == Magus.Knowledge.Connectors.GoogleDrive
    end

    test "returns the Notion module for :notion" do
      assert Connector.connector_for(:notion) == Magus.Knowledge.Connectors.Notion
    end

    test "returns the Nextcloud module for :nextcloud" do
      assert Connector.connector_for(:nextcloud) == Magus.Knowledge.Connectors.Nextcloud
    end

    test "returns the Affine module for :affine" do
      assert Connector.connector_for(:affine) == Magus.Knowledge.Connectors.Affine
    end

    test "returns an error tuple for unknown providers" do
      assert Connector.connector_for(:dropbox) == {:error, {:unsupported_provider, :dropbox}}
      assert Connector.connector_for(:unknown) == {:error, {:unsupported_provider, :unknown}}
    end
  end

  describe "MockConnector behaviour contract" do
    setup do
      {:ok, conn} = MockConnector.connect(%{api_key: "test-key"})
      %{conn: conn}
    end

    test "connect/1 succeeds with valid auth config" do
      assert {:ok, %{token: "test-key"}} = MockConnector.connect(%{api_key: "test-key"})
    end

    test "connect/1 fails with invalid auth config" do
      assert {:error, :bad_credentials} = MockConnector.connect(%{})
    end

    test "list_folders/2 returns folders for nil path", %{conn: conn} do
      assert {:ok, [%{id: "root", name: "Root", path: "/"}]} =
               MockConnector.list_folders(conn, nil)
    end

    test "list_folders/2 returns subfolders for a given path", %{conn: conn} do
      assert {:ok, [%{id: "sub", path: "/docs/sub"}]} =
               MockConnector.list_folders(conn, "/docs")
    end

    test "list_items/3 returns first page and a cursor", %{conn: conn} do
      collection = %{id: "col-1"}

      assert {:ok, [%{id: "item-1"}], %{next: "page2"}} =
               MockConnector.list_items(conn, collection, nil)
    end

    test "list_items/3 returns second page with nil cursor when done", %{conn: conn} do
      collection = %{id: "col-1"}

      assert {:ok, [%{id: "item-2"}], nil} =
               MockConnector.list_items(conn, collection, %{next: "page2"})
    end

    test "fetch_content/2 returns binary content and metadata", %{conn: conn} do
      item = %{id: "item-1"}
      assert {:ok, content, %{word_count: _}} = MockConnector.fetch_content(conn, item)
      assert is_binary(content)
    end

    test "detect_changes/3 returns a list of changes", %{conn: conn} do
      collection = %{id: "col-1"}
      since = ~U[2026-01-15 00:00:00Z]

      assert {:ok, [%{type: :updated, item: %{id: "item-1"}}]} =
               MockConnector.detect_changes(conn, collection, since)
    end

    test "register_webhook/3 returns a webhook ID", %{conn: conn} do
      collection = %{id: "col-1"}

      assert {:ok, webhook_id} =
               MockConnector.register_webhook(conn, collection, "https://example.com/hook")

      assert is_binary(webhook_id)
    end

    test "create_item/5 returns the created item", %{conn: conn} do
      collection = %{id: "col-1"}

      assert {:ok, %{id: "new-item", name: "report.md"}} =
               MockConnector.create_item(conn, collection, "report.md", "# Report", %{
                 mime_type: "text/markdown"
               })
    end

    test "update_item/5 returns the updated item", %{conn: conn} do
      collection = %{id: "col-1"}

      assert {:ok, %{id: "item-1"}} =
               MockConnector.update_item(conn, collection, "item-1", "# Updated", %{
                 name: "updated.md"
               })
    end
  end
end
