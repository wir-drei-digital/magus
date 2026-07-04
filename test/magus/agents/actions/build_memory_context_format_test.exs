defmodule Magus.Agents.Actions.BuildMemoryContextFormatTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Actions.BuildMemoryContext

  defp mem(name, opts \\ []) do
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
end
