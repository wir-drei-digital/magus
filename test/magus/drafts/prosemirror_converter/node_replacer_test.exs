defmodule Magus.Drafts.ProseMirrorConverter.NodeReplacerTest do
  use ExUnit.Case, async: true

  alias Magus.Drafts.ProseMirrorConverter
  alias Magus.Drafts.ProseMirrorConverter.NodeReplacer

  # Helper to build a doc from markdown and verify replacement
  defp doc_from_md!(md) do
    {:ok, doc} = ProseMirrorConverter.from_markdown(md)
    doc
  end

  describe "replace_text/4" do
    test "replaces single occurrence in a paragraph" do
      doc = doc_from_md!("Hello world, this is a test.")
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "world", "universe", nil)
      assert ProseMirrorConverter.to_markdown(new_doc) == "Hello universe, this is a test."
    end

    test "replaces text spanning formatted content" do
      doc = doc_from_md!("Hello **bold** world")
      # The markdown representation is "Hello **bold** world"
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "**bold**", "**strong**", nil)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "Hello **strong** world"
    end

    test "replaces entire paragraph" do
      doc = doc_from_md!("First paragraph\n\nSecond paragraph\n\nThird paragraph")

      assert {:ok, new_doc} =
               NodeReplacer.replace_text(doc, "Second paragraph", "Replaced paragraph", nil)

      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "First paragraph\n\nReplaced paragraph\n\nThird paragraph"
    end

    test "replaces text in code block" do
      doc = doc_from_md!("```elixir\nIO.puts(\"hello\")\n```")

      assert {:ok, new_doc} =
               NodeReplacer.replace_text(doc, "IO.puts(\"hello\")", "IO.puts(\"world\")", nil)

      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "```elixir\nIO.puts(\"world\")\n```"
    end

    test "replaces heading text" do
      doc = doc_from_md!("# Old Title\n\nSome content")
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "# Old Title", "# New Title", nil)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "# New Title\n\nSome content"
    end

    test "replaces list item" do
      doc = doc_from_md!("- item 1\n- item 2\n- item 3")
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "- item 2", "- replaced", nil)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "- item 1\n- replaced\n- item 3"
    end

    test "returns error when text not found" do
      doc = doc_from_md!("Hello world")

      assert {:error, "text not found in document"} =
               NodeReplacer.replace_text(doc, "xyz", "abc", nil)
    end

    test "returns error for empty old_text" do
      doc = doc_from_md!("Hello")

      assert {:error, "old_text must not be empty"} =
               NodeReplacer.replace_text(doc, "", "abc", nil)
    end

    test "disambiguates with hint_line when multiple occurrences" do
      doc = doc_from_md!("Hello world\n\nSome text\n\nHello world")

      # The markdown is:
      # Line 1: Hello world
      # Line 2: (empty)
      # Line 3: Some text
      # Line 4: (empty)
      # Line 5: Hello world

      # Replace the second occurrence (near line 5)
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "Hello world", "Goodbye world", 5)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "Hello world\n\nSome text\n\nGoodbye world"

      # Replace the first occurrence (near line 1)
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "Hello world", "Goodbye world", 1)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "Goodbye world\n\nSome text\n\nHello world"
    end

    test "returns error for multiple occurrences without hint_line" do
      doc = doc_from_md!("Hello world\n\nHello world")

      assert {:error, "found 2 occurrences; provide hint_line to disambiguate"} =
               NodeReplacer.replace_text(doc, "Hello world", "Goodbye", nil)
    end

    test "replacement that changes structure (paragraph to heading)" do
      doc = doc_from_md!("A plain paragraph")

      assert {:ok, new_doc} =
               NodeReplacer.replace_text(doc, "A plain paragraph", "## A heading now", nil)

      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "## A heading now"
    end

    test "replacement that expands one paragraph to multiple" do
      doc = doc_from_md!("One paragraph only")

      assert {:ok, new_doc} =
               NodeReplacer.replace_text(
                 doc,
                 "One paragraph only",
                 "First\n\nSecond\n\nThird",
                 nil
               )

      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "First\n\nSecond\n\nThird"
    end

    test "replacement with empty new_text removes content" do
      doc = doc_from_md!("Keep this\n\nRemove this\n\nKeep this too")
      assert {:ok, new_doc} = NodeReplacer.replace_text(doc, "\n\nRemove this", "", nil)
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "Keep this\n\nKeep this too"
    end
  end

  describe "replace_at_positions/4" do
    test "replaces content at valid positions" do
      doc = doc_from_md!("Hello world")

      # ProseMirror positions for a simple paragraph:
      # 0: doc open
      # 1: paragraph open
      # 2-12: "Hello world" (11 chars)
      # 13: paragraph close
      # Position from=1 to=13 covers the entire paragraph

      assert {:ok, new_doc} = NodeReplacer.replace_at_positions(doc, 0, 13, "Goodbye world")
      assert ProseMirrorConverter.to_markdown(new_doc) == "Goodbye world"
    end

    test "replaces a specific block in multi-block doc" do
      doc = doc_from_md!("First\n\nSecond\n\nThird")

      # Block positions:
      # Block 0 (First):  0 to 7  (open=0, text "First"=5 chars, close=7)
      # Block 1 (Second): 7 to 15 (open=7, text "Second"=6 chars, close=15)
      # Block 2 (Third):  15 to 22

      assert {:ok, new_doc} = NodeReplacer.replace_at_positions(doc, 7, 15, "Replaced")
      md = ProseMirrorConverter.to_markdown(new_doc)
      assert md == "First\n\nReplaced\n\nThird"
    end

    test "returns error for invalid positions" do
      doc = doc_from_md!("Hello")
      assert {:error, "invalid positions"} = NodeReplacer.replace_at_positions(doc, 5, 3, "x")
    end

    test "returns error for out-of-range positions" do
      doc = doc_from_md!("Hello")

      assert {:error, "positions out of range"} =
               NodeReplacer.replace_at_positions(doc, 100, 200, "x")
    end
  end

  describe "extract_text_at_positions/3" do
    test "extracts text from a simple paragraph" do
      doc = doc_from_md!("Hello world")

      # Position 1 is paragraph open, text starts at position 1
      # "Hello world" is 11 chars at positions 1..11
      assert {:ok, text} = NodeReplacer.extract_text_at_positions(doc, 1, 6)
      assert text == "Hello"
    end

    test "extracts text from multiple blocks" do
      doc = doc_from_md!("First\n\nSecond")

      # Extract all text from first paragraph
      assert {:ok, text} = NodeReplacer.extract_text_at_positions(doc, 1, 6)
      assert text == "First"
    end
  end
end
