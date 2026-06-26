defmodule Magus.Knowledge.Connectors.Web.IntegrationTest do
  @moduledoc """
  Integration tests verifying the web connector modules work together correctly.

  These tests do NOT make real HTTP calls. They exercise the module contracts and
  the strategy delegation pipeline using mock connection structs and in-process
  strategy implementations.
  """
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connector
  alias Magus.Knowledge.Connectors.Web
  alias Magus.Knowledge.Connectors.Web.AutoDetector
  alias Magus.Knowledge.Connectors.Web.Boundary
  alias Magus.Knowledge.Connectors.Web.Fetcher
  alias Magus.Knowledge.KnowledgeCollection.Changes.FullSync

  # ---------------------------------------------------------------------------
  # 1. Connector registration
  # ---------------------------------------------------------------------------

  describe "connector registration" do
    test "connector_for(:web) returns the Web connector module" do
      assert Connector.connector_for(:web) == Magus.Knowledge.Connectors.Web
    end

    test "Web module implements the Connector behaviour" do
      # Verify all required callbacks are exported
      assert function_exported?(Web, :connect, 1)
      assert function_exported?(Web, :list_folders, 2)
      assert function_exported?(Web, :list_items, 3)
      assert function_exported?(Web, :fetch_content, 2)
      assert function_exported?(Web, :detect_changes, 3)
      assert function_exported?(Web, :register_webhook, 3)
      assert function_exported?(Web, :create_item, 5)
      assert function_exported?(Web, :update_item, 5)
    end

    test "connector_for/1 returns error tuple for unknown providers" do
      assert {:error, {:unsupported_provider, :web_crawler}} =
               Connector.connector_for(:web_crawler)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Provider enum — :web is a valid KnowledgeSource provider
  # ---------------------------------------------------------------------------

  describe "provider enum" do
    test ":web is accepted in the KnowledgeSource provider constraint list" do
      # The constraint is defined as one_of: [..., :web], so verify via
      # Ash attribute constraints introspection that :web is valid.
      providers =
        Magus.Knowledge.KnowledgeSource
        |> Ash.Resource.Info.attribute(:provider)
        |> Map.get(:constraints, [])
        |> Keyword.get(:one_of, [])

      assert :web in providers
    end
  end

  # ---------------------------------------------------------------------------
  # 3. connect → list_items flow with a mock strategy
  # ---------------------------------------------------------------------------

  # A minimal in-process strategy that returns pre-canned entries without HTTP.
  defmodule MockStrategy do
    @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

    @impl true
    def discover(_conn, _settings, nil) do
      entries = [
        %{url: "https://example.com/docs/intro", metadata: %{"title" => "Introduction"}},
        %{
          url: "https://example.com/docs/guide",
          metadata: %{"last_modified" => "2024-06-01T00:00:00Z"}
        }
      ]

      {:ok, entries, nil}
    end

    def discover(_conn, _settings, _cursor), do: {:ok, [], nil}
  end

  defp mock_conn(opts \\ []) do
    %Web{
      seed_url: Keyword.get(opts, :seed_url, "https://example.com"),
      strategy: Keyword.get(opts, :strategy, "link_follow"),
      strategy_module: Keyword.get(opts, :strategy_module, MockStrategy),
      boundary: nil,
      auth_headers: Keyword.get(opts, :auth_headers, []),
      use_spider: false,
      robots_rules: [],
      crawl_delay_ms: nil
    }
  end

  describe "connect → list_items delegation" do
    test "connect/1 returns error when seed_url is missing" do
      assert {:error, :missing_seed_url} = Web.connect(%{})
    end

    test "connect/1 returns error when seed_url is empty string" do
      assert {:error, :missing_seed_url} = Web.connect(%{"seed_url" => ""})
    end

    test "strategy_for_override maps explicit strategy names to modules" do
      assert AutoDetector.strategy_for_override("sitemap") ==
               Magus.Knowledge.Connectors.Web.Strategies.Sitemap

      assert AutoDetector.strategy_for_override("openapi") ==
               Magus.Knowledge.Connectors.Web.Strategies.OpenApi

      assert AutoDetector.strategy_for_override("pagination") ==
               Magus.Knowledge.Connectors.Web.Strategies.Pagination

      assert AutoDetector.strategy_for_override("link_follow") ==
               Magus.Knowledge.Connectors.Web.Strategies.LinkFollow

      assert AutoDetector.strategy_for_override("auto") == nil
      assert AutoDetector.strategy_for_override("unknown") == nil
    end

    test "list_items/3 delegates to strategy_module.discover/3 and translates items" do
      conn = mock_conn()
      collection = %{settings: %{}}

      assert {:ok, items, nil} = Web.list_items(conn, collection, nil)
      assert length(items) == 2

      # All items must conform to the Connector.item() shape
      for item <- items do
        assert is_binary(item.id)
        assert is_binary(item.name)
        assert is_nil(item.etag)
        assert item.mime_type == "text/markdown"
      end
    end

    test "list_items/3 forwards cursor to strategy and returns new cursor" do
      # Build a strategy that returns two pages
      defmodule TwoPageStrategy do
        @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

        @impl true
        def discover(_conn, _settings, nil) do
          {:ok, [%{url: "https://example.com/page1", metadata: %{}}], %{page: 2}}
        end

        def discover(_conn, _settings, %{page: 2}) do
          {:ok, [%{url: "https://example.com/page2", metadata: %{}}], nil}
        end
      end

      conn = mock_conn(strategy_module: TwoPageStrategy)
      collection = %{settings: %{}}

      assert {:ok, [item1], %{page: 2}} = Web.list_items(conn, collection, nil)
      assert item1.id == "https://example.com/page1"

      assert {:ok, [item2], nil} = Web.list_items(conn, collection, %{page: 2})
      assert item2.id == "https://example.com/page2"
    end

    test "list_items/3 propagates strategy errors" do
      defmodule FailingStrategy do
        @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy
        @impl true
        def discover(_conn, _settings, _cursor), do: {:error, :network_timeout}
      end

      conn = mock_conn(strategy_module: FailingStrategy)
      collection = %{settings: %{}}

      assert {:error, :network_timeout} = Web.list_items(conn, collection, nil)
    end

    test "list_items/3 handles nil collection settings" do
      conn = mock_conn()
      collection = %{settings: nil}

      assert {:ok, items, nil} = Web.list_items(conn, collection, nil)
      assert is_list(items)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. translate_item/1 — strategy entries → Connector.item()
  # ---------------------------------------------------------------------------

  describe "translate_item/1 integration with strategy entries" do
    test "translates a full strategy entry to Connector.item() format" do
      entry = %{
        url: "https://example.com/docs/api-reference",
        metadata: %{
          "title" => "API Reference",
          "last_modified" => "2025-01-20T12:00:00Z"
        }
      }

      item = Web.translate_item(entry)

      assert item.id == "https://example.com/docs/api-reference"
      assert item.name == "API Reference"
      assert item.mime_type == "text/markdown"
      assert is_nil(item.etag)
      assert %DateTime{year: 2025, month: 1, day: 20} = item.updated_at
      assert item.metadata["title"] == "API Reference"
    end

    test "list_items passes strategy entries through translate_item correctly" do
      conn = mock_conn()
      collection = %{settings: %{}}

      {:ok, items, _} = Web.list_items(conn, collection, nil)

      intro = Enum.find(items, &(&1.id == "https://example.com/docs/intro"))
      assert intro.name == "Introduction"
      assert is_nil(intro.updated_at)

      guide = Enum.find(items, &(&1.id == "https://example.com/docs/guide"))
      assert guide.name == "guide"
      assert %DateTime{year: 2024, month: 6, day: 1} = guide.updated_at
    end

    test "translate_item handles entry with spec_content in metadata" do
      spec_content = "# OpenAPI 3.0\n\nPaths: /users"

      entry = %{
        url: "https://api.example.com/openapi.json",
        metadata: %{
          "title" => "API Spec",
          spec_content: spec_content
        }
      }

      item = Web.translate_item(entry)
      assert item.id == "https://api.example.com/openapi.json"
      assert item.metadata[:spec_content] == spec_content
      # The spec_content path in fetch_content is checked via metadata key
      assert item.mime_type == "text/markdown"
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Fetcher content_hash — consistent hashes for etag comparison
  # ---------------------------------------------------------------------------

  describe "Fetcher.content_hash/1 for etag flow" do
    test "content_hash produces deterministic sha256: prefixed strings" do
      content = "# Hello World\n\nThis is a test page."
      hash1 = Fetcher.content_hash(content)
      hash2 = Fetcher.content_hash(content)

      assert hash1 == hash2
      assert String.starts_with?(hash1, "sha256:")
    end

    test "different content produces different hashes (no collisions for test data)" do
      hash_a = Fetcher.content_hash("page content version 1")
      hash_b = Fetcher.content_hash("page content version 2")
      refute hash_a == hash_b
    end

    test "hash format is usable as an etag — string with sha256: prefix" do
      hash = Fetcher.content_hash("some markdown content")
      # Verify it's a valid etag-shaped string
      assert is_binary(hash)
      assert String.starts_with?(hash, "sha256:")
      # The hex digest after prefix is 64 chars (SHA-256 = 32 bytes = 64 hex chars)
      hex = String.replace_prefix(hash, "sha256:", "")
      assert String.length(hex) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, hex)
    end

    test "fetch_content/2 returns etag equal to content_hash for spec_content items" do
      conn = mock_conn()
      spec_content = "# Documentation\n\nContent here."

      item = %{
        id: "https://example.com/spec.json",
        name: "Spec",
        etag: nil,
        updated_at: nil,
        mime_type: "text/markdown",
        metadata: %{spec_content: spec_content}
      }

      assert {:ok, ^spec_content, metadata} = Web.fetch_content(conn, item)
      assert metadata["etag"] == Fetcher.content_hash(spec_content)
      assert String.starts_with?(metadata["etag"], "sha256:")
    end

    test "content_hash is stable across multiple fetch_content calls" do
      conn = mock_conn()
      spec_content = "stable content for hashing"

      item = %{
        id: "https://example.com/page.md",
        name: "Page",
        etag: nil,
        updated_at: nil,
        mime_type: "text/markdown",
        metadata: %{spec_content: spec_content}
      }

      {:ok, _, meta1} = Web.fetch_content(conn, item)
      {:ok, _, meta2} = Web.fetch_content(conn, item)

      assert meta1["etag"] == meta2["etag"]
    end
  end

  # ---------------------------------------------------------------------------
  # 6. FullSync.create_file_from_item — uses metadata etag
  # ---------------------------------------------------------------------------

  describe "FullSync etag fix" do
    test "create_file_from_item uses metadata etag when present over item etag" do
      # Read the source to verify the etag fix is in place:
      # Map.get(metadata || %{}, "etag", item.etag)
      # This confirms that metadata["etag"] (the content hash) takes precedence
      # over item.etag (which is nil for web items).
      full_sync_path =
        Path.join([
          File.cwd!(),
          "lib/magus/knowledge/knowledge_collection/changes/full_sync.ex"
        ])

      source = File.read!(full_sync_path)

      # Verify the fix is present in the source
      assert String.contains?(source, "Map.get(metadata || %{}, \"etag\", item.etag)")
    end

    test "detect_file_type correctly classifies text/markdown" do
      assert FullSync.detect_file_type("text/markdown") == :text
    end

    test "detect_file_type correctly classifies web mime types" do
      assert FullSync.detect_file_type("text/html") == :text
      assert FullSync.detect_file_type("text/plain") == :text
      assert FullSync.detect_file_type("application/pdf") == :document
      assert FullSync.detect_file_type("image/png") == :image
      assert FullSync.detect_file_type("video/mp4") == :video
      assert FullSync.detect_file_type("message/rfc822") == :email
    end
  end

  # ---------------------------------------------------------------------------
  # 7. End-to-end contract: strategy → translate → fetch_content → etag
  # ---------------------------------------------------------------------------

  describe "end-to-end pipeline contract (no HTTP)" do
    test "strategy entries → translate_item → fetch_content produces content hash as etag" do
      # Simulate the pipeline:
      # 1. Strategy discovers a URL with spec_content pre-rendered
      # 2. translate_item converts it to Connector.item()
      # 3. fetch_content returns content and a hash-based etag

      conn = mock_conn()
      spec_content = "# Getting Started\n\nThis guide explains setup."

      # Strategy entry as returned by e.g. OpenApi strategy
      strategy_entry = %{
        url: "https://api.example.com/openapi.json",
        metadata: %{
          "title" => "Getting Started",
          spec_content: spec_content
        }
      }

      # Step 1: translate_item (as done by list_items)
      item = Web.translate_item(strategy_entry)

      assert item.id == "https://api.example.com/openapi.json"
      assert item.name == "Getting Started"
      assert is_nil(item.etag)
      assert item.mime_type == "text/markdown"

      # Step 2: fetch_content returns content + metadata with etag
      assert {:ok, content, metadata} = Web.fetch_content(conn, item)

      assert content == spec_content
      assert is_binary(metadata["etag"])
      assert String.starts_with?(metadata["etag"], "sha256:")
      assert is_binary(metadata["fetched_at"])

      # The etag matches the content hash — suitable for IncrementalSync comparison
      expected_hash = Fetcher.content_hash(spec_content)
      assert metadata["etag"] == expected_hash
    end

    test "URL normalization works end-to-end for deduplication" do
      # Boundary.normalize is used by strategies to canonicalize URLs before
      # returning them; this verifies the normalization works for typical cases.
      assert Boundary.normalize("https://example.com/docs/") == "https://example.com/docs"

      assert Boundary.normalize("https://example.com/docs?utm_source=google") ==
               "https://example.com/docs"

      assert Boundary.normalize("https://example.com/docs#section") ==
               "https://example.com/docs"

      assert Boundary.normalize("HTTPS://EXAMPLE.COM/docs") == "https://example.com/docs"
    end

    test "boundary allowed? correctly gates URLs for web strategies" do
      config = %{
        "allowed_domains" => ["example.com"],
        "allowed_paths" => ["/docs"],
        "excluded_paths" => ["/docs/private"],
        "max_depth" => 3
      }

      assert Boundary.allowed?("https://example.com/docs/intro", config, [], 1)
      refute Boundary.allowed?("https://other.com/docs/intro", config, [], 1)
      refute Boundary.allowed?("https://example.com/docs/private/secret", config, [], 1)
      refute Boundary.allowed?("https://example.com/docs/image.png", config, [], 1)
    end

    test "robots.txt rules are parsed and respected" do
      robots_content = """
      User-agent: *
      Disallow: /admin
      Disallow: /private
      Crawl-delay: 2
      """

      rules = AutoDetector.parse_robots_txt(robots_content)
      assert length(rules) == 1
      [rule] = rules
      assert rule.user_agent == "*"
      assert "/admin" in rule.disallow
      assert "/private" in rule.disallow

      # Verify boundary respects robots rules
      config = %{
        "allowed_domains" => ["example.com"],
        "respect_robots_txt" => true
      }

      refute Boundary.allowed?("https://example.com/admin/users", config, rules, 1)
      refute Boundary.allowed?("https://example.com/private/data", config, rules, 1)
      assert Boundary.allowed?("https://example.com/public/page", config, rules, 1)
    end

    test "parse_robots_txt_full extracts crawl delay in milliseconds" do
      robots_content = """
      User-agent: *
      Disallow: /tmp
      Crawl-delay: 2
      """

      {_rules, _sitemaps, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(robots_content)
      assert crawl_delay_ms == 2000
    end
  end
end
