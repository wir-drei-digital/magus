defmodule Magus.Knowledge.Connectors.Web.FetcherTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.Fetcher

  describe "content_hash/1" do
    test "returns sha256 prefixed hash" do
      hash = Fetcher.content_hash("hello world")
      assert String.starts_with?(hash, "sha256:")
    end

    test "returns consistent hash for same content" do
      assert Fetcher.content_hash("test content") == Fetcher.content_hash("test content")
    end

    test "returns different hash for different content" do
      refute Fetcher.content_hash("content A") == Fetcher.content_hash("content B")
    end

    test "hash hex part is 64 characters (SHA-256)" do
      hash = Fetcher.content_hash("some data")
      hex = String.replace_prefix(hash, "sha256:", "")
      assert byte_size(hex) == 64
    end

    test "handles empty string" do
      hash = Fetcher.content_hash("")
      assert String.starts_with?(hash, "sha256:")
      hex = String.replace_prefix(hash, "sha256:", "")
      assert byte_size(hex) == 64
    end
  end

  describe "truncate_content/2" do
    test "returns content unchanged when under limit" do
      content = "short content"
      assert Fetcher.truncate_content(content, 500_000) == content
    end

    test "truncates content at byte limit and appends marker" do
      # Create content longer than 20 bytes
      content = String.duplicate("a", 25)
      result = Fetcher.truncate_content(content, 20)
      assert byte_size(result) > 20
      assert String.ends_with?(result, "\n\n[Content truncated]")
      # The truncated portion is 20 bytes of "a"
      truncated_part = String.replace_suffix(result, "\n\n[Content truncated]", "")
      assert byte_size(truncated_part) == 20
    end

    test "uses default limit of 500_000 bytes" do
      short_content = "hello"
      assert Fetcher.truncate_content(short_content) == short_content
    end

    test "truncates content exactly at limit boundary" do
      content = String.duplicate("x", 500_000)
      result = Fetcher.truncate_content(content)
      assert result == content
    end

    test "truncates content over 500_000 bytes" do
      content = String.duplicate("x", 500_001)
      result = Fetcher.truncate_content(content)
      assert String.ends_with?(result, "\n\n[Content truncated]")
      truncated_part = String.replace_suffix(result, "\n\n[Content truncated]", "")
      assert byte_size(truncated_part) == 500_000
    end
  end

  describe "detect_content_type/1" do
    test "detects html content type from map headers" do
      headers = %{"content-type" => ["text/html; charset=utf-8"]}
      assert Fetcher.detect_content_type(headers) == :html
    end

    test "detects json content type from map headers" do
      headers = %{"content-type" => ["application/json"]}
      assert Fetcher.detect_content_type(headers) == :json
    end

    test "detects xml content type from map headers" do
      headers = %{"content-type" => ["application/xml"]}
      assert Fetcher.detect_content_type(headers) == :xml
    end

    test "detects text/xml content type" do
      headers = %{"content-type" => ["text/xml; charset=utf-8"]}
      assert Fetcher.detect_content_type(headers) == :xml
    end

    test "returns :other for unknown content type" do
      headers = %{"content-type" => ["application/octet-stream"]}
      assert Fetcher.detect_content_type(headers) == :other
    end

    test "returns :other when content-type header is absent" do
      headers = %{}
      assert Fetcher.detect_content_type(headers) == :other
    end

    test "handles tuple format headers (old Req format)" do
      headers = [{"content-type", "text/html"}]
      assert Fetcher.detect_content_type(headers) == :html
    end

    test "handles tuple format for json" do
      headers = [{"content-type", "application/json"}]
      assert Fetcher.detect_content_type(headers) == :json
    end

    test "handles uppercase content-type header name in tuples" do
      headers = [{"Content-Type", "text/html"}]
      assert Fetcher.detect_content_type(headers) == :html
    end

    test "detects html from application/xhtml+xml" do
      headers = %{"content-type" => ["application/xhtml+xml"]}
      assert Fetcher.detect_content_type(headers) == :html
    end
  end

  describe "format_json_as_markdown/1" do
    test "formats map as json code block" do
      data = %{"key" => "value"}
      result = Fetcher.format_json_as_markdown(data)
      assert String.starts_with?(result, "```json\n")
      assert String.ends_with?(result, "\n```")
    end

    test "formats list as json code block" do
      data = [1, 2, 3]
      result = Fetcher.format_json_as_markdown(data)
      assert String.starts_with?(result, "```json\n")
      assert String.ends_with?(result, "\n```")
    end

    test "contains valid JSON inside the code block" do
      data = %{"name" => "test", "value" => 42}
      result = Fetcher.format_json_as_markdown(data)
      # Extract JSON from code block
      inner =
        result |> String.replace_prefix("```json\n", "") |> String.replace_suffix("\n```", "")

      assert {:ok, decoded} = Jason.decode(inner)
      assert decoded["name"] == "test"
      assert decoded["value"] == 42
    end

    test "formats nested structures" do
      data = %{"nested" => %{"a" => [1, 2, 3]}}
      result = Fetcher.format_json_as_markdown(data)
      assert String.starts_with?(result, "```json\n")
      assert String.ends_with?(result, "\n```")
    end
  end
end
