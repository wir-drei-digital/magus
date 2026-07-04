defmodule Magus.Agents.Actions.BuildMemoryContextFormatTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Actions.BuildMemoryContext

  defp mem(name, opts) do
    %{
      name: name,
      summary: Keyword.get(opts, :summary, "summary of #{name}"),
      content: Keyword.get(opts, :content, %{}),
      display_scope: Keyword.get(opts, :scope, :local),
      kind: Keyword.get(opts, :kind, :general),
      confidence: Keyword.get(opts, :confidence, 0.7)
    }
  end

  test "confidence is never rendered" do
    out = BuildMemoryContext.format_context([mem("A", confidence: 0.7)], [], true)
    refute out =~ "confidence"
  end

  test "content previews are capped at 600 chars" do
    big = %{"data" => String.duplicate("x", 3000)}
    out = BuildMemoryContext.format_context([mem("A", content: big)], [], true)
    assert out =~ "(truncated)"

    [_, preview] = String.split(out, "```json", parts: 2)
    [preview, _] = String.split(preview, "```", parts: 2)
    assert String.length(preview) <= 700
  end

  test "previews: false omits content JSON entirely" do
    big = %{"data" => String.duplicate("x", 3000)}
    out = BuildMemoryContext.format_context([mem("A", content: big)], [], true, previews: false)
    refute out =~ "```json"
    assert out =~ "search_memories"
  end

  describe "empty-context regression (no real memory content)" do
    test "no memories + global disabled returns empty string, not a disabled-note block" do
      out = BuildMemoryContext.format_context([], [], false)
      assert out == ""
      refute out =~ "## Your Memory"
      refute out =~ "Global memory is disabled"
    end

    test "no memories + global enabled returns empty string, not a tip block" do
      out = BuildMemoryContext.format_context([], [], true)
      assert out == ""
      refute out =~ "## Your Memory"
      refute out =~ "Create global memories"
    end

    test "profile document with empty important/semantic renders the profile section without the global-memory tip" do
      out =
        BuildMemoryContext.format_context([], [], true,
          profile_document: "## Preferences\nConcise answers."
        )

      assert out =~ "## Your Memory"
      assert out =~ "### User Profile"
      assert out =~ "Concise answers."
      refute out =~ "Create global memories"
      refute out =~ "Global memory is disabled"
    end

    test "a non-empty important memory (no profile) still renders the block as before" do
      out = BuildMemoryContext.format_context([mem("A", [])], [], false)
      assert out =~ "## Your Memory"
      assert out =~ "### Key Memories"
    end
  end
end
