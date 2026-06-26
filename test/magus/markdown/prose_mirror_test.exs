defmodule Magus.Markdown.ProseMirrorTest do
  use ExUnit.Case, async: true
  alias Magus.Markdown.ProseMirror

  test "from_markdown/1 converts standard markdown (default profile)" do
    assert {:ok, %{"type" => "doc", "content" => content}} =
             ProseMirror.from_markdown("# Hi\n\n- [x] done")

    assert Enum.any?(content, &(&1["type"] == "heading"))
    assert Enum.any?(content, &(&1["type"] == "taskList"))
  end

  test "to_markdown/1 round-trips a tasklist" do
    {:ok, doc} = ProseMirror.from_markdown("- [ ] a\n- [x] b")
    assert ProseMirror.to_markdown(doc) == "- [ ] a\n- [x] b"
  end

  test "default profile does not lift brain fences" do
    {:ok, doc} = ProseMirror.from_markdown("```callout\nvariant: note\ntext: hi\n```")
    assert Enum.any?(doc["content"], &(&1["type"] == "codeBlock"))
    refute Enum.any?(doc["content"], &(&1["type"] == "calloutBlock"))
  end

  describe "mark coalescing (C1)" do
    defp rt(md), do: ProseMirror.to_markdown(elem(ProseMirror.from_markdown(md), 1))

    test "bold spanning a code span round-trips and converges" do
      assert rt("**a `b` c**") == "**a `b` c**"
      # idempotent / converges
      assert rt(rt("**a `b` c**")) == "**a `b` c**"
    end

    test "emphasis spanning a link round-trips" do
      assert rt("*see [docs](https://x.com) now*") == "*see [docs](https://x.com) now*"
    end

    test "bold link round-trips" do
      assert rt("[**bold**](https://x.com)") == "[**bold**](https://x.com)"
    end

    test "simple marks unchanged" do
      assert rt("**bold**") == "**bold**"
      assert rt("*italic*") == "*italic*"
      assert rt("`code`") == "`code`"
      assert rt("[l](https://x.com)") == "[l](https://x.com)"
      assert rt("a **b** c") == "a **b** c"
      assert rt("**bold** and *italic* and `code`") == "**bold** and *italic* and `code`"
    end
  end

  describe "image titles (I1)" do
    test "title round-trips" do
      assert rt("![alt](https://x.com/i.png \"My Title\")") ==
               "![alt](https://x.com/i.png \"My Title\")"
    end

    test "no title unchanged" do
      assert rt("![alt](https://x.com/i.png)") == "![alt](https://x.com/i.png)"
    end
  end
end
