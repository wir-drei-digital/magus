defmodule Magus.Drafts.MarkdownResolverTest do
  use ExUnit.Case, async: true

  alias Magus.Drafts.MarkdownResolver

  # ---------------------------------------------------------------------------
  # strip_markdown_inline/1
  # ---------------------------------------------------------------------------

  describe "strip_markdown_inline/1" do
    test "strips bold markers" do
      assert MarkdownResolver.strip_markdown_inline("some **bold** text") == "some bold text"
      assert MarkdownResolver.strip_markdown_inline("__also bold__") == "also bold"
    end

    test "strips italic markers" do
      assert MarkdownResolver.strip_markdown_inline("some *italic* text") == "some italic text"
    end

    test "strips underscore italic" do
      assert MarkdownResolver.strip_markdown_inline("some _italic_ text") == "some italic text"
    end

    test "does not strip underscores inside identifiers" do
      assert MarkdownResolver.strip_markdown_inline("my_variable_name") == "my_variable_name"
    end

    test "strips inline code" do
      assert MarkdownResolver.strip_markdown_inline("use `mix test` here") == "use mix test here"
    end

    test "strips links" do
      assert MarkdownResolver.strip_markdown_inline("see [docs](https://example.com) for info") ==
               "see docs for info"
    end

    test "strips images" do
      assert MarkdownResolver.strip_markdown_inline("![alt text](image.png)") == "alt text"
    end

    test "strips heading prefixes" do
      assert MarkdownResolver.strip_markdown_inline("## My Heading") == "My Heading"
      assert MarkdownResolver.strip_markdown_inline("### Sub Heading") == "Sub Heading"
    end

    test "strips blockquote prefix" do
      assert MarkdownResolver.strip_markdown_inline("> quoted text") == "quoted text"
    end

    test "strips list markers" do
      assert MarkdownResolver.strip_markdown_inline("- list item") == "list item"
      assert MarkdownResolver.strip_markdown_inline("* star item") == "star item"
      assert MarkdownResolver.strip_markdown_inline("1. ordered item") == "ordered item"
    end

    test "strips strikethrough" do
      assert MarkdownResolver.strip_markdown_inline("~~removed~~") == "removed"
    end

    test "handles combined formatting" do
      assert MarkdownResolver.strip_markdown_inline("## A **bold** [link](url) here") ==
               "A bold link here"
    end

    test "leaves plain text unchanged" do
      assert MarkdownResolver.strip_markdown_inline("just plain text") == "just plain text"
    end

    test "handles multi-byte UTF-8 characters" do
      assert MarkdownResolver.strip_markdown_inline("**Grüße** an alle") == "Grüße an alle"
      assert MarkdownResolver.strip_markdown_inline("## Überschrift") == "Überschrift"
    end

    test "strips nested blockquotes" do
      assert MarkdownResolver.strip_markdown_inline(">> nested quote") == "nested quote"
      assert MarkdownResolver.strip_markdown_inline("> > deep") == "deep"
    end

    test "strips task list checkboxes" do
      assert MarkdownResolver.strip_markdown_inline("[x] checked item") == "checked item"
      assert MarkdownResolver.strip_markdown_inline("[ ] unchecked item") == "unchecked item"
    end

    test "strips double-backtick code spans" do
      assert MarkdownResolver.strip_markdown_inline("use ``code here`` please") ==
               "use code here please"
    end
  end

  # ---------------------------------------------------------------------------
  # strip_markdown_lines/1
  # ---------------------------------------------------------------------------

  describe "strip_markdown_lines/1" do
    test "preserves content inside fenced code blocks" do
      lines = [
        "Some text",
        "```elixir",
        "**not bold**",
        "# not a heading",
        "```",
        "**bold** outside"
      ]

      assert MarkdownResolver.strip_markdown_lines(lines) == [
               "Some text",
               "```elixir",
               "**not bold**",
               "# not a heading",
               "```",
               "bold outside"
             ]
    end

    test "handles multiple fenced code blocks" do
      lines = [
        "**bold**",
        "```",
        "_kept_",
        "```",
        "*italic*",
        "```",
        "__kept__",
        "```",
        "~~struck~~"
      ]

      assert MarkdownResolver.strip_markdown_lines(lines) == [
               "bold",
               "```",
               "_kept_",
               "```",
               "italic",
               "```",
               "__kept__",
               "```",
               "struck"
             ]
    end

    test "strips all lines when no code blocks" do
      lines = ["## Heading", "**bold** text", "- item"]

      assert MarkdownResolver.strip_markdown_lines(lines) == [
               "Heading",
               "bold text",
               "item"
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # resolve/3
  # ---------------------------------------------------------------------------

  describe "resolve/3" do
    test "returns selected_text when it matches raw content verbatim" do
      content = "Hello world\nSecond line"
      assert MarkdownResolver.resolve(content, "Hello world", nil) == "Hello world"
    end

    test "returns verbatim when rendered text is a substring of raw content" do
      # "Title" exists as a substring inside "# Title", so the verbatim
      # fast path applies — replace_draft_text will replace just "Title"
      content = "# Title\n\nSome body text"
      assert MarkdownResolver.resolve(content, "Title", 1) == "Title"
    end

    test "maps rendered selection back to raw markdown lines" do
      content = "Intro\n**bold statement** here\nEnd"

      result = MarkdownResolver.resolve(content, "bold statement here", 2)
      assert result == "**bold statement** here"
    end

    test "handles multi-line selection with markdown" do
      content = "## Section\n**Important** point\nPlain line"

      result = MarkdownResolver.resolve(content, "Section\nImportant point", 1)
      assert result == "## Section\n**Important** point"
    end

    test "falls through with original text when nothing matches" do
      content = "Hello world"

      assert MarkdownResolver.resolve(content, "completely different", nil) ==
               "completely different"
    end

    test "handles multi-byte UTF-8 content" do
      content = "## Überschrift\n**Grüße** an alle\nEnde"

      result = MarkdownResolver.resolve(content, "Überschrift\nGrüße an alle", 1)
      assert result == "## Überschrift\n**Grüße** an alle"
    end

    test "fast path matches substring inside formatted span" do
      # "bold text" is a substring of "**bold text**" in the raw content,
      # so the fast path returns it verbatim. replace_draft_text will then
      # replace just the inner substring, preserving the ** markers.
      content = "no bold\n**bold text**"
      assert MarkdownResolver.resolve(content, "bold text", 2) == "bold text"
    end

    test "preserves code block content during resolution" do
      content = "Intro\n```\n**not bold**\n```\n**real bold** text"

      # Selecting rendered "real bold text" should match the last line
      result = MarkdownResolver.resolve(content, "real bold text", 5)
      assert result == "**real bold** text"
    end
  end

  # ---------------------------------------------------------------------------
  # find_raw_by_stripping/3
  # ---------------------------------------------------------------------------

  describe "find_raw_by_stripping/3" do
    test "uses hint_line to disambiguate multiple matches" do
      content = "**word** first\nother line\n**word** second"

      assert {:ok, "**word** second"} =
               MarkdownResolver.find_raw_by_stripping(content, "word second", 3)

      assert {:ok, "**word** first"} =
               MarkdownResolver.find_raw_by_stripping(content, "word first", 1)
    end

    test "disambiguates truly identical stripped matches via hint_line" do
      content = "**hello** world\nmiddle\n**hello** world\nfinal"

      {:ok, raw1} = MarkdownResolver.find_raw_by_stripping(content, "hello world\nmiddle", 1)
      assert raw1 == "**hello** world\nmiddle"

      {:ok, raw2} = MarkdownResolver.find_raw_by_stripping(content, "hello world\nfinal", 3)
      assert raw2 == "**hello** world\nfinal"
    end

    test "picks first match when hint_line is nil" do
      content = "**word** here\n**word** there"

      assert {:ok, "**word** here"} =
               MarkdownResolver.find_raw_by_stripping(content, "word here", nil)
    end

    test "returns :not_found when text doesn't match even after stripping" do
      assert :not_found = MarkdownResolver.find_raw_by_stripping("Some **md** text", "xyz", nil)
    end

    test "handles empty content" do
      assert :not_found = MarkdownResolver.find_raw_by_stripping("", "text", nil)
    end
  end
end
