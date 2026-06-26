defmodule Magus.Brain.DiffTest do
  use ExUnit.Case, async: true

  alias Magus.Brain.Diff

  test "identical bodies produce no rows" do
    assert Diff.line_word_diff("same\ntext", "same\ntext") == []
  end

  test "pure addition yields only :ins rows" do
    rows = Diff.line_word_diff("", "line1\nline2")
    assert Enum.all?(rows, &(&1.kind == :ins))
    assert length(rows) == 2
  end

  test "pure deletion yields only :del rows" do
    rows = Diff.line_word_diff("a\nb", "")
    assert Enum.all?(rows, &(&1.kind == :del))
    assert length(rows) == 2
  end

  test "intra-line word change highlights only the changed word" do
    rows = Diff.line_word_diff("The quick brown fox", "The slow brown fox")
    del = Enum.find(rows, &(&1.kind == :del))
    ins = Enum.find(rows, &(&1.kind == :ins))

    assert {:removed, "quick"} in del.tokens
    assert {:added, "slow"} in ins.tokens
    assert {:same, "The "} in del.tokens
    assert {:same, " brown fox"} in ins.tokens
  end

  test "multi-line replace keeps surrounding lines as :context" do
    rows = Diff.line_word_diff("line1\nline2\nline3", "line1\nCHANGED\nline3")
    kinds = Enum.map(rows, & &1.kind)
    assert kinds == [:context, :del, :ins, :context]
  end

  test "long unchanged runs collapse to a :gap row" do
    old = "x\nL1\nL2\nL3\nL4\nL5\nz"
    new = "X\nL1\nL2\nL3\nL4\nL5\nZ"
    rows = Diff.line_word_diff(old, new, context: 1)
    gap = Enum.find(rows, &(&1.kind == :gap))
    assert gap.count == 3
  end

  test "an empty line paired with a non-empty line yields a del row with empty tokens" do
    rows = Diff.line_word_diff("\nfoo", "bar\nbaz")
    assert Enum.any?(rows, &(&1.kind == :del and &1.tokens == []))
  end

  test "context: 0 collapses surrounding unchanged lines into gaps" do
    rows = Diff.line_word_diff("a\nMID\nb", "a\nMID2\nb", context: 0)
    assert Enum.any?(rows, &(&1.kind == :gap))
  end
end
