defmodule Magus.Brain.ChunkerTest do
  use ExUnit.Case, async: true

  alias Magus.Brain.Chunker

  describe "chunk/2" do
    test "returns empty for nil, empty, or whitespace-only input" do
      assert Chunker.chunk(nil) == []
      assert Chunker.chunk("") == []
      assert Chunker.chunk("   \n   ") == []
    end

    test "single paragraph becomes a single chunk at index 0" do
      assert [%{content: "Hello world", index: 0, token_count: tokens}] =
               Chunker.chunk("Hello world")

      assert is_integer(tokens) and tokens > 0
    end

    test "joins multiple short paragraphs into a single chunk under the size cap" do
      text = "Para one.\n\nPara two.\n\nPara three."

      assert [%{content: content, index: 0}] = Chunker.chunk(text, chunk_size: 100)
      assert content =~ "Para one."
      assert content =~ "Para two."
      assert content =~ "Para three."
    end

    test "splits into multiple chunks when paragraphs exceed the cap" do
      # ~50 tokens each paragraph
      para = String.duplicate("word ", 50)
      text = Enum.join([para, para, para, para], "\n\n")

      chunks = Chunker.chunk(text, chunk_size: 100)

      assert length(chunks) >= 2
      assert Enum.map(chunks, & &1.index) == Enum.to_list(0..(length(chunks) - 1))
    end

    test "a single paragraph larger than the cap becomes its own oversized chunk" do
      big = String.duplicate("alpha ", 500)
      chunks = Chunker.chunk(big, chunk_size: 100)

      assert length(chunks) == 1
      assert hd(chunks).token_count > 100
    end

    test "is deterministic for the same input" do
      text = "Para one.\n\nPara two.\n\nPara three."
      assert Chunker.chunk(text) == Chunker.chunk(text)
    end

    test "drops blank paragraphs from the split" do
      text = "Para one.\n\n\n\nPara two."
      assert [%{content: content}] = Chunker.chunk(text, chunk_size: 1000)
      assert content == "Para one.\n\nPara two."
    end

    test "strips YAML frontmatter by default so it doesn't pollute embeddings" do
      body = """
      ---
      icon: 🧠
      tags: [ml, research]
      ---

      The real content of the page.
      """

      [chunk | _] = Chunker.chunk(body)
      refute chunk.content =~ "icon:"
      refute chunk.content =~ "tags:"
      refute chunk.content =~ "---"
      assert chunk.content =~ "real content"
    end

    test "keeps frontmatter when strip_frontmatter: false" do
      body = "---\nicon: 🧠\n---\nbody"
      [chunk | _] = Chunker.chunk(body, strip_frontmatter: false)
      assert chunk.content =~ "icon"
    end

    test "indices are sequential starting at 0" do
      para = String.duplicate("word ", 50)
      text = Enum.join([para, para, para, para, para], "\n\n")
      chunks = Chunker.chunk(text, chunk_size: 60)

      Enum.with_index(chunks)
      |> Enum.each(fn {chunk, expected_idx} ->
        assert chunk.index == expected_idx
      end)
    end
  end
end
