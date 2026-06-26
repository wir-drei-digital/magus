defmodule Magus.Brain.BodyParserTest do
  use ExUnit.Case, async: true

  alias Magus.Brain.BodyParser

  describe "wikilinks/1" do
    test "extracts target names from `[[Page Name]]`" do
      body = "See [[Project Alpha]] and [[Notes]] for details."
      assert BodyParser.wikilinks(body) == ["Project Alpha", "Notes"]
    end

    test "strips pipe alias and uses target before the pipe" do
      body = "Reference: [[Original Title|short name]]"
      assert BodyParser.wikilinks(body) == ["Original Title"]
    end

    test "skips message refs `[[msg:...]]`" do
      body = "[[msg:abc-123]] and [[msg:def-456|preview]]"
      assert BodyParser.wikilinks(body) == []
    end

    test "deduplicates repeated links" do
      body = "[[Foo]] and again [[Foo]]"
      assert BodyParser.wikilinks(body) == ["Foo"]
    end

    test "handles nil and empty body" do
      assert BodyParser.wikilinks(nil) == []
      assert BodyParser.wikilinks("") == []
      assert BodyParser.wikilinks("no links here") == []
    end
  end

  describe "source_urls/1" do
    test "extracts urls from ```source fences" do
      body = """
      Some text

      ```source
      url: https://example.com
      title: Example
      ```

      More text.

      ```source
      url: https://other.example
      source_type: paper
      ```
      """

      assert BodyParser.source_urls(body) == [
               "https://example.com",
               "https://other.example"
             ]
    end

    test "preserves document order" do
      body = """
      ```source
      url: https://z.example
      ```

      ```source
      url: https://a.example
      ```
      """

      assert BodyParser.source_urls(body) == ["https://z.example", "https://a.example"]
    end

    test "skips fences without a url field" do
      body = """
      ```source
      title: Bare
      ```
      """

      assert BodyParser.source_urls(body) == []
    end

    test "handles quoted urls" do
      body = """
      ```source
      url: "https://example.com/path with spaces"
      ```
      """

      assert BodyParser.source_urls(body) == ["https://example.com/path with spaces"]
    end

    test "handles nil and empty body" do
      assert BodyParser.source_urls(nil) == []
      assert BodyParser.source_urls("") == []
    end
  end

  describe "file_ids/1" do
    test "extracts ids from `magus://file/<uuid>` attachment links" do
      body = "See [📎 spec](magus://file/11111111-1111-1111-1111-111111111111)."
      assert BodyParser.file_ids(body) == ["11111111-1111-1111-1111-111111111111"]
    end

    test "extracts ids from `magus://image/<uuid>` image embeds" do
      body = "![alt](magus://image/22222222-2222-2222-2222-222222222222)"
      assert BodyParser.file_ids(body) == ["22222222-2222-2222-2222-222222222222"]
    end

    test "preserves first-occurrence order across file and image refs" do
      body = """
      ![one](magus://image/11111111-1111-1111-1111-111111111111)

      [📎 two](magus://file/22222222-2222-2222-2222-222222222222)
      """

      assert BodyParser.file_ids(body) == [
               "11111111-1111-1111-1111-111111111111",
               "22222222-2222-2222-2222-222222222222"
             ]
    end

    test "deduplicates repeated ids regardless of file/image scheme" do
      id = "11111111-1111-1111-1111-111111111111"
      body = "[📎 a](magus://file/#{id}) and again ![](magus://image/#{id})"
      assert BodyParser.file_ids(body) == [id]
    end

    test "accepts ULID-shaped ids (26 alphanumeric chars)" do
      ulid = "01h45ytz1k7n6q0c7m6mfx0prq"
      body = "[📎 a](magus://file/#{ulid})"
      assert BodyParser.file_ids(body) == [ulid]
    end

    test "ignores other magus:// schemes" do
      body = "Look at [[msg:abc]] or magus://page/something."
      assert BodyParser.file_ids(body) == []
    end

    test "handles nil and empty body" do
      assert BodyParser.file_ids(nil) == []
      assert BodyParser.file_ids("") == []
      assert BodyParser.file_ids("no file refs here") == []
    end
  end

  describe "inline_tags/1" do
    test "extracts and normalizes inline `#tag` occurrences" do
      body = "Working on #machine-learning and #Research today."
      assert "machine-learning" in BodyParser.inline_tags(body)
      assert "research" in BodyParser.inline_tags(body)
    end

    test "deduplicates" do
      body = "#ml #ML #ml"
      assert BodyParser.inline_tags(body) == ["ml"]
    end

    test "ignores tags inside code fences" do
      body = "Outside #real\n\n```\nInside #not-a-tag\n```"
      assert BodyParser.inline_tags(body) == ["real"]
    end

    test "requires a word boundary before the #" do
      body = "URLs like https://example.com/page#fragment should not count"
      refute "fragment" in BodyParser.inline_tags(body)
    end

    test "handles nil and empty" do
      assert BodyParser.inline_tags(nil) == []
      assert BodyParser.inline_tags("") == []
    end
  end
end
