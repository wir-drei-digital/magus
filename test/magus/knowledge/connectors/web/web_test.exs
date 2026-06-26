defmodule Magus.Knowledge.Connectors.WebTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web

  # ---------------------------------------------------------------------------
  # build_auth_headers/1
  # ---------------------------------------------------------------------------

  describe "build_auth_headers/1" do
    test "returns empty list for auth_type none" do
      assert Web.build_auth_headers(%{"auth_type" => "none"}) == []
    end

    test "returns empty list when auth_type is missing" do
      assert Web.build_auth_headers(%{}) == []
    end

    test "returns bearer Authorization header" do
      headers = Web.build_auth_headers(%{"auth_type" => "bearer", "token" => "sk-abc123"})
      assert [{"Authorization", "Bearer sk-abc123"}] = headers
    end

    test "bearer with empty token produces header with empty token" do
      headers = Web.build_auth_headers(%{"auth_type" => "bearer"})
      assert [{"Authorization", "Bearer "}] = headers
    end

    test "returns api_key header with default header name" do
      headers = Web.build_auth_headers(%{"auth_type" => "api_key", "api_key" => "key-xyz"})
      assert [{"X-Api-Key", "key-xyz"}] = headers
    end

    test "returns api_key header with custom header name" do
      headers =
        Web.build_auth_headers(%{
          "auth_type" => "api_key",
          "api_key" => "key-xyz",
          "api_key_header" => "X-Custom-Header"
        })

      assert [{"X-Custom-Header", "key-xyz"}] = headers
    end

    test "returns basic Authorization header" do
      headers =
        Web.build_auth_headers(%{
          "auth_type" => "basic",
          "username" => "user",
          "password" => "pass"
        })

      expected = Base.encode64("user:pass")
      assert [{"Authorization", "Basic " <> ^expected}] = headers
    end

    test "returns empty list for unrecognised auth_type" do
      assert Web.build_auth_headers(%{"auth_type" => "oauth2"}) == []
    end

    test "returns empty list for non-map input" do
      assert Web.build_auth_headers(nil) == []
      assert Web.build_auth_headers("bearer token") == []
    end
  end

  # ---------------------------------------------------------------------------
  # translate_item/1
  # ---------------------------------------------------------------------------

  describe "translate_item/1" do
    test "uses metadata title as name when present" do
      entry = %{url: "https://example.com/page", metadata: %{"title" => "My Page"}}
      item = Web.translate_item(entry)
      assert item.name == "My Page"
    end

    test "derives name from URL path segment when no title" do
      entry = %{url: "https://example.com/docs/getting-started", metadata: %{}}
      item = Web.translate_item(entry)
      assert item.name == "getting-started"
    end

    test "falls back to full URL when path is empty" do
      entry = %{url: "https://example.com", metadata: %{}}
      item = Web.translate_item(entry)
      assert item.name == "https://example.com"
    end

    test "sets id to the URL" do
      url = "https://example.com/page"
      item = Web.translate_item(%{url: url, metadata: %{}})
      assert item.id == url
    end

    test "sets etag to nil" do
      item = Web.translate_item(%{url: "https://example.com/page", metadata: %{}})
      assert is_nil(item.etag)
    end

    test "sets mime_type to text/markdown" do
      item = Web.translate_item(%{url: "https://example.com/page", metadata: %{}})
      assert item.mime_type == "text/markdown"
    end

    test "parses ISO8601 last_modified into DateTime" do
      entry = %{
        url: "https://example.com/page",
        metadata: %{"last_modified" => "2024-01-15T10:30:00Z"}
      }

      item = Web.translate_item(entry)
      assert %DateTime{year: 2024, month: 1, day: 15} = item.updated_at
    end

    test "sets updated_at to nil when last_modified is absent" do
      item = Web.translate_item(%{url: "https://example.com/page", metadata: %{}})
      assert is_nil(item.updated_at)
    end

    test "sets updated_at to nil for unparseable last_modified" do
      entry = %{url: "https://example.com/page", metadata: %{"last_modified" => "not-a-date"}}
      item = Web.translate_item(entry)
      assert is_nil(item.updated_at)
    end

    test "accepts entry without metadata key" do
      item = Web.translate_item(%{url: "https://example.com/page"})
      assert item.id == "https://example.com/page"
      assert item.mime_type == "text/markdown"
    end

    test "preserves metadata on item" do
      metadata = %{"title" => "Hello", "extra" => "value"}
      item = Web.translate_item(%{url: "https://example.com/page", metadata: metadata})
      assert item.metadata == metadata
    end
  end

  # ---------------------------------------------------------------------------
  # Unsupported callbacks
  # ---------------------------------------------------------------------------

  describe "unsupported callbacks" do
    setup do
      conn = %Web{
        seed_url: "https://example.com",
        strategy: "auto",
        strategy_module: nil,
        boundary: nil,
        auth_headers: [],
        use_spider: false,
        robots_rules: [],
        crawl_delay_ms: nil
      }

      {:ok, conn: conn}
    end

    test "detect_changes returns :not_supported", %{conn: conn} do
      assert {:error, :not_supported} =
               Web.detect_changes(conn, %{}, DateTime.utc_now())
    end

    test "register_webhook returns :not_supported", %{conn: conn} do
      assert {:error, :not_supported} =
               Web.register_webhook(conn, %{}, "https://callback.example.com")
    end

    test "create_item returns :not_supported", %{conn: conn} do
      assert {:error, :not_supported} =
               Web.create_item(conn, %{}, "name", "content", %{})
    end

    test "update_item returns :not_supported", %{conn: conn} do
      assert {:error, :not_supported} =
               Web.update_item(conn, %{}, "external-id", "content", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # list_folders/2
  # ---------------------------------------------------------------------------

  describe "list_folders/2" do
    test "returns single folder with seed_url as id" do
      conn = %Web{seed_url: "https://example.com/docs", auth_headers: []}
      assert {:ok, [folder]} = Web.list_folders(conn, nil)
      assert folder.id == "https://example.com/docs"
      assert folder.name == "Web Source"
      assert folder.path == "/"
    end
  end

  # ---------------------------------------------------------------------------
  # Connector registry
  # ---------------------------------------------------------------------------

  describe "connector_for/1" do
    test "returns Web module for :web provider" do
      assert Magus.Knowledge.Connector.connector_for(:web) ==
               Magus.Knowledge.Connectors.Web
    end
  end

  # ---------------------------------------------------------------------------
  # fetch_content/2 — spec_only shortcut (no HTTP)
  # ---------------------------------------------------------------------------

  describe "fetch_content/2 with spec_only item" do
    test "returns spec_content directly and includes etag in metadata" do
      conn = %Web{
        seed_url: "https://example.com/openapi.json",
        auth_headers: [],
        crawl_delay_ms: nil,
        robots_rules: [],
        strategy_module: nil
      }

      spec_content = "# API Docs\n\nSome content here."

      item = %{
        id: "https://example.com/openapi.json",
        name: "OpenAPI Spec",
        etag: nil,
        updated_at: nil,
        mime_type: "text/markdown",
        metadata: %{spec_content: spec_content}
      }

      assert {:ok, content, metadata} = Web.fetch_content(conn, item)
      assert content == spec_content
      assert Map.has_key?(metadata, "etag")
      assert String.starts_with?(metadata["etag"], "sha256:")
      assert Map.has_key?(metadata, "fetched_at")
    end

    test "etag is deterministic content hash" do
      conn = %Web{
        seed_url: "https://example.com/openapi.json",
        auth_headers: [],
        crawl_delay_ms: nil,
        robots_rules: [],
        strategy_module: nil
      }

      spec_content = "deterministic content"

      item = %{
        id: "https://example.com/openapi.json",
        name: "Spec",
        etag: nil,
        updated_at: nil,
        mime_type: "text/markdown",
        metadata: %{spec_content: spec_content}
      }

      {:ok, _, meta1} = Web.fetch_content(conn, item)
      {:ok, _, meta2} = Web.fetch_content(conn, item)

      assert meta1["etag"] == meta2["etag"]

      alias Magus.Knowledge.Connectors.Web.Fetcher
      assert meta1["etag"] == Fetcher.content_hash(spec_content)
    end
  end
end
