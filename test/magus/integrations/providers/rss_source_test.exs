defmodule Magus.Integrations.Providers.RssSourceTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.RssSource

  describe "metadata" do
    test "returns correct key and auth type" do
      assert RssSource.key() == :rss_source
      assert RssSource.auth_type() == :none
      assert RssSource.source_type() == :data_source
    end

    test "returns search tools" do
      tools = RssSource.tools()
      assert length(tools) == 2
    end
  end

  describe "classify/1" do
    test "all RSS items default to info severity" do
      assert %{severity: :info, title: nil} = RssSource.classify(%{content: "Article about AI"})
    end
  end

  describe "parse_ingestion_payload/2" do
    test "parses RSS-style items from poll results" do
      payload = %{
        "items" => [
          %{
            "title" => "New Release v2.0",
            "link" => "https://example.com/post/1",
            "description" => "We released version 2.0",
            "pub_date" => "2026-03-21T10:00:00Z"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.title == "New Release v2.0"
      assert entry.metadata["url"] == "https://example.com/post/1"
    end

    test "parses multiple items" do
      payload = %{
        "items" => [
          %{
            "title" => "Post 1",
            "link" => "https://example.com/1",
            "description" => "First post"
          },
          %{
            "title" => "Post 2",
            "link" => "https://example.com/2",
            "description" => "Second post"
          }
        ]
      }

      assert {:ok, entries} = RssSource.parse_ingestion_payload(payload, [])
      assert length(entries) == 2
    end

    test "uses link as external_id" do
      payload = %{
        "items" => [
          %{
            "title" => "Post",
            "link" => "https://example.com/unique",
            "description" => "Content"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.external_id == "https://example.com/unique"
    end

    test "generates external_id from content when no link" do
      payload = %{
        "items" => [
          %{
            "title" => "No Link Post",
            "description" => "Content without link"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert is_binary(entry.external_id)
      assert String.length(entry.external_id) == 16
    end

    test "combines title and description into content" do
      payload = %{
        "items" => [
          %{
            "title" => "My Title",
            "description" => "My Description"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.content == "My Title\n\nMy Description"
    end

    test "handles missing title" do
      payload = %{
        "items" => [
          %{
            "description" => "Just a description"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.content == "Just a description"
      assert entry.title == nil
    end

    test "parses ISO 8601 timestamps" do
      payload = %{
        "items" => [
          %{
            "title" => "Post",
            "pub_date" => "2026-03-21T10:30:00Z"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.occurred_at == ~U[2026-03-21 10:30:00Z]
    end

    test "falls back to current time for invalid timestamps" do
      payload = %{
        "items" => [
          %{
            "title" => "Post",
            "pub_date" => "not-a-date"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert %DateTime{} = entry.occurred_at
    end

    test "returns error for invalid payload" do
      assert {:error, {:invalid_payload, _}} = RssSource.parse_ingestion_payload(%{}, [])
    end

    test "captures author in metadata" do
      payload = %{
        "items" => [
          %{
            "title" => "Post",
            "author" => "Jane Doe"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.metadata["author"] == "Jane Doe"
    end

    test "supports alternative field names" do
      payload = %{
        "items" => [
          %{
            "title" => "Atom Post",
            "url" => "https://example.com/atom",
            "summary" => "Atom summary",
            "published" => "2026-03-21T12:00:00Z",
            "creator" => "Author Name"
          }
        ]
      }

      assert {:ok, [entry]} = RssSource.parse_ingestion_payload(payload, [])
      assert entry.metadata["url"] == "https://example.com/atom"
      assert entry.metadata["author"] == "Author Name"
      assert entry.occurred_at == ~U[2026-03-21 12:00:00Z]
    end
  end
end
