defmodule Magus.Agents.Tools.Sandbox.SandboxHelpersTest do
  @moduledoc """
  Tests for the SandboxHelpers utility module.

  Tests cover:
  - find_closest_match/2: exact, fuzzy, and no-match cases
  - strip_line_prefixes/1: stripping line number prefixes when majority present
  - build_unified_diff/3: unified diff output with context collapsing
  - truncate_output/2: byte-limit truncation preserving line boundaries
  - cap_line_length/2: per-line character capping
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Sandbox.SandboxHelpers

  # ---------------------------------------------------------------------------
  # find_closest_match/2
  # ---------------------------------------------------------------------------

  describe "find_closest_match/2" do
    test "returns :exact when search is found verbatim" do
      content = "hello world\nfoo bar\nbaz"
      assert SandboxHelpers.find_closest_match(content, "foo bar") == {:exact, "foo bar"}
    end

    test "returns :exact for multiline search found verbatim" do
      content = "line one\nline two\nline three"

      assert SandboxHelpers.find_closest_match(content, "line one\nline two") ==
               {:exact, "line one\nline two"}
    end

    test "returns :exact when entire content matches" do
      content = "only line"
      assert SandboxHelpers.find_closest_match(content, "only line") == {:exact, "only line"}
    end

    test "returns :fuzzy when search has line number prefixes that normalize to a match" do
      content = "def foo do\n  :ok\nend"
      # Model copied from read output: "  1| def foo do"
      search = "  1| def foo do\n  2|   :ok\n  3| end"

      assert {:fuzzy, _line, candidate} = SandboxHelpers.find_closest_match(content, search)
      assert candidate == "def foo do\n  :ok\nend"
    end

    test "returns :fuzzy when search has leading whitespace stripped per line" do
      # Content has consistent indentation but search lacks it
      content = "  hello\n  world\n  foo"
      search = "hello\nworld\nfoo"

      assert {:fuzzy, _line, candidate} = SandboxHelpers.find_closest_match(content, search)
      assert String.contains?(candidate, "hello")
    end

    test "returns :no_match when search not found and normalization fails" do
      content = "hello world\nfoo bar"
      assert SandboxHelpers.find_closest_match(content, "completely different text") == :no_match
    end

    test "returns :no_match for empty content" do
      assert SandboxHelpers.find_closest_match("", "foo") == :no_match
    end

    test "returns :exact for single character match" do
      assert SandboxHelpers.find_closest_match("abc", "b") == {:exact, "b"}
    end

    test "returns :no_match when search is empty string" do
      # Empty string matches everywhere, but we treat it as no useful match
      assert SandboxHelpers.find_closest_match("hello", "") == :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # strip_line_prefixes/1
  # ---------------------------------------------------------------------------

  describe "strip_line_prefixes/1" do
    test "strips single-digit line number prefixes" do
      input = "  1| hello\n  2| world\n  3| foo"
      assert SandboxHelpers.strip_line_prefixes(input) == "hello\nworld\nfoo"
    end

    test "strips double-digit line number prefixes" do
      input = " 10| hello\n 11| world\n 12| foo"
      assert SandboxHelpers.strip_line_prefixes(input) == "hello\nworld\nfoo"
    end

    test "strips triple-digit line number prefixes" do
      input = "100| hello\n101| world\n102| foo"
      assert SandboxHelpers.strip_line_prefixes(input) == "hello\nworld\nfoo"
    end

    test "strips mixed width prefixes" do
      input = "  1| first\n  9| ninth\n 10| tenth\n 99| ninety-ninth\n100| one-hundredth"

      assert SandboxHelpers.strip_line_prefixes(input) ==
               "first\nninth\ntenth\nninety-ninth\none-hundredth"
    end

    test "does not strip when fewer than 70% of lines have prefix" do
      # Only 2 of 4 lines have prefix = 50%, below 70% threshold
      input = "  1| hello\nplain line\nplain line\n  4| world"
      assert SandboxHelpers.strip_line_prefixes(input) == input
    end

    test "strips when 70% or more of lines have prefix" do
      # 3 of 4 lines have prefix = 75%, at or above 70% threshold
      input = "  1| hello\n  2| world\n  3| foo\nplain line"
      result = SandboxHelpers.strip_line_prefixes(input)
      assert result == "hello\nworld\nfoo\nplain line"
    end

    test "returns unchanged text with no line prefixes" do
      input = "hello\nworld\nfoo"
      assert SandboxHelpers.strip_line_prefixes(input) == input
    end

    test "handles single line with prefix" do
      input = "  1| hello"
      assert SandboxHelpers.strip_line_prefixes(input) == "hello"
    end

    test "handles empty string" do
      assert SandboxHelpers.strip_line_prefixes("") == ""
    end

    test "preserves indentation within lines after stripping prefix" do
      input = "  1|   indented code\n  2|     more indented"
      assert SandboxHelpers.strip_line_prefixes(input) == "  indented code\n    more indented"
    end
  end

  # ---------------------------------------------------------------------------
  # build_unified_diff/3
  # ---------------------------------------------------------------------------

  describe "build_unified_diff/3" do
    test "shows header with filename" do
      diff = SandboxHelpers.build_unified_diff("hello", "world", "test.txt")
      assert String.starts_with?(diff, "--- test.txt\n+++ test.txt\n")
    end

    test "marks added lines with +" do
      diff = SandboxHelpers.build_unified_diff("", "new line", "f.txt")
      assert String.contains?(diff, "+new line")
    end

    test "marks deleted lines with -" do
      diff = SandboxHelpers.build_unified_diff("old line", "", "f.txt")
      assert String.contains?(diff, "-old line")
    end

    test "marks equal lines with space prefix" do
      diff = SandboxHelpers.build_unified_diff("same\nchanged", "same\nnew", "f.txt")
      assert String.contains?(diff, " same")
    end

    test "shows replacement as delete then insert" do
      old = "line one\nline two\nline three"
      new = "line one\nLINE TWO\nline three"
      diff = SandboxHelpers.build_unified_diff(old, new, "f.txt")

      assert String.contains?(diff, "-line two")
      assert String.contains?(diff, "+LINE TWO")
      assert String.contains?(diff, " line one")
      assert String.contains?(diff, " line three")
    end

    test "collapses long equal sections to first 3 and last 3 lines" do
      # Build content with 10 unchanged lines, then a change
      old_lines = Enum.map(1..10, &"line #{&1}")
      new_lines = old_lines

      old = Enum.join(old_lines, "\n")
      new_content = Enum.join(new_lines, "\n") <> "\nextra line"

      diff = SandboxHelpers.build_unified_diff(old, new_content, "f.txt")

      # Should collapse the middle of the equal section
      assert String.contains?(diff, "unchanged lines")
    end

    test "does not collapse equal sections of 6 or fewer lines" do
      old = "a\nb\nc\nd\ne\nf"
      new_content = old <> "\ng"
      diff = SandboxHelpers.build_unified_diff(old, new_content, "f.txt")

      # All 6 lines should appear as context (with space prefix)
      assert String.contains?(diff, " a")
      assert String.contains?(diff, " f")
      refute String.contains?(diff, "unchanged lines")
    end

    test "handles identical content" do
      content = "same content"
      diff = SandboxHelpers.build_unified_diff(content, content, "f.txt")
      # Header contains +++ and --- but no actual change lines
      lines = diff |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "+++"))
      refute Enum.any?(lines, &String.starts_with?(&1, "+"))
      lines2 = diff |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "---"))
      refute Enum.any?(lines2, &String.starts_with?(&1, "-"))
    end

    test "handles empty old content" do
      diff = SandboxHelpers.build_unified_diff("", "new content", "f.txt")
      assert String.contains?(diff, "+new content")
    end

    test "handles empty new content" do
      diff = SandboxHelpers.build_unified_diff("old content", "", "f.txt")
      assert String.contains?(diff, "-old content")
    end
  end

  # ---------------------------------------------------------------------------
  # truncate_output/2
  # ---------------------------------------------------------------------------

  describe "truncate_output/2" do
    test "returns :ok when content is under limit" do
      content = "short content"
      assert SandboxHelpers.truncate_output(content, 1000) == {:ok, content}
    end

    test "returns :ok when content is exactly at limit" do
      content = String.duplicate("a", 100)
      assert SandboxHelpers.truncate_output(content, 100) == {:ok, content}
    end

    test "returns :truncated when content exceeds limit" do
      content = String.duplicate("a", 200)

      assert {:truncated, _truncated, original_size} =
               SandboxHelpers.truncate_output(content, 100)

      assert original_size == 200
    end

    test "truncates at last newline before limit" do
      # 10 chars + newline + 10 chars = 21 chars total
      content = "0123456789\n0123456789"
      assert {:truncated, truncated, _} = SandboxHelpers.truncate_output(content, 15)
      # Should cut at the newline after the first 10 chars
      assert String.starts_with?(truncated, "0123456789")
      refute String.contains?(truncated, "0123456789\n0123456789")
    end

    test "appended hint shows bytes shown vs total" do
      content = "line one\nline two\nline three\nline four"
      assert {:truncated, truncated, original_size} = SandboxHelpers.truncate_output(content, 20)
      assert original_size == byte_size(content)
      assert String.contains?(truncated, "bytes")
    end

    test "handles content with no newlines before limit" do
      # Single long line — no newline to cut at, truncates at byte limit
      content = String.duplicate("x", 200)
      assert {:truncated, truncated, _} = SandboxHelpers.truncate_output(content, 100)
      assert byte_size(truncated) > 0
    end

    test "handles empty content" do
      assert SandboxHelpers.truncate_output("", 100) == {:ok, ""}
    end
  end

  # ---------------------------------------------------------------------------
  # cap_line_length/2
  # ---------------------------------------------------------------------------

  describe "cap_line_length/2" do
    test "returns content unchanged when all lines are within limit" do
      content = "short\nlines\nhere"
      assert SandboxHelpers.cap_line_length(content, 100) == content
    end

    test "truncates lines exceeding the limit" do
      long_line = String.duplicate("a", 200)
      result = SandboxHelpers.cap_line_length(long_line, 100)
      assert String.length(result) < String.length(long_line)
    end

    test "appends truncation hint with char count" do
      long_line = String.duplicate("a", 200)
      result = SandboxHelpers.cap_line_length(long_line, 100)
      assert String.contains?(result, "chars")
    end

    test "only truncates long lines, leaving short ones intact" do
      content = "short line\n" <> String.duplicate("x", 200) <> "\nanother short"
      result = SandboxHelpers.cap_line_length(content, 50)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == "short line"
      assert String.contains?(Enum.at(lines, 1), "chars")
      assert Enum.at(lines, 2) == "another short"
    end

    test "handles exactly at limit" do
      line = String.duplicate("a", 100)
      assert SandboxHelpers.cap_line_length(line, 100) == line
    end

    test "handles empty content" do
      assert SandboxHelpers.cap_line_length("", 100) == ""
    end

    test "handles content with empty lines" do
      content = "line one\n\nline three"
      assert SandboxHelpers.cap_line_length(content, 100) == content
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_quotes/1
  # ---------------------------------------------------------------------------

  describe "normalize_quotes/1" do
    test "converts left double curly quote to straight" do
      assert SandboxHelpers.normalize_quotes("\u201Chello\u201D") == "\"hello\""
    end

    test "converts single curly quotes to straight" do
      assert SandboxHelpers.normalize_quotes("it\u2019s a \u2018test\u2019") == "it's a 'test'"
    end

    test "leaves straight quotes unchanged" do
      assert SandboxHelpers.normalize_quotes("\"hello\" 'world'") == "\"hello\" 'world'"
    end

    test "handles mixed curly and straight quotes" do
      assert SandboxHelpers.normalize_quotes("\u201Chello\" \u2018world'") == "\"hello\" 'world'"
    end

    test "handles text without quotes" do
      assert SandboxHelpers.normalize_quotes("no quotes here") == "no quotes here"
    end
  end

  # ---------------------------------------------------------------------------
  # find_with_quote_normalization/2
  # ---------------------------------------------------------------------------

  describe "find_with_quote_normalization/2" do
    test "returns exact match when string found verbatim" do
      content = "hello world"

      assert {^content, :exact} =
               SandboxHelpers.find_with_quote_normalization(content, "hello world")
    end

    test "finds curly-quoted string using straight quotes" do
      content = "She said \u201Chello\u201D to him"

      {actual, :normalized} =
        SandboxHelpers.find_with_quote_normalization(content, "She said \"hello\" to him")

      assert actual == "She said \u201Chello\u201D to him"
    end

    test "finds single curly quote with straight quote" do
      content = "it\u2019s fine"
      {actual, :normalized} = SandboxHelpers.find_with_quote_normalization(content, "it's fine")
      assert actual == "it\u2019s fine"
    end

    test "returns not_found when no match even after normalization" do
      assert :not_found = SandboxHelpers.find_with_quote_normalization("hello", "goodbye")
    end
  end

  # ---------------------------------------------------------------------------
  # strip_trailing_whitespace/1
  # ---------------------------------------------------------------------------

  describe "strip_trailing_whitespace/1" do
    test "strips trailing spaces from each line" do
      assert SandboxHelpers.strip_trailing_whitespace("hello   \nworld  ") == "hello\nworld"
    end

    test "strips trailing tabs" do
      assert SandboxHelpers.strip_trailing_whitespace("hello\t\t\nworld\t") == "hello\nworld"
    end

    test "preserves leading whitespace" do
      assert SandboxHelpers.strip_trailing_whitespace("  hello  \n  world  ") ==
               "  hello\n  world"
    end

    test "handles empty string" do
      assert SandboxHelpers.strip_trailing_whitespace("") == ""
    end

    test "handles lines with only whitespace" do
      assert SandboxHelpers.strip_trailing_whitespace("  \n  \n  ") == "\n\n"
    end
  end

  # ---------------------------------------------------------------------------
  # apply_edit/4
  # ---------------------------------------------------------------------------

  describe "apply_edit/4" do
    test "exact match replacement" do
      content = "hello world"

      assert {:ok, "hello elixir", %{replacements: 1}} =
               SandboxHelpers.apply_edit(content, "world", "elixir")
    end

    test "replace_all replaces multiple occurrences" do
      content = "foo bar foo baz foo"

      assert {:ok, result, %{replacements: 3}} =
               SandboxHelpers.apply_edit(content, "foo", "qux", true)

      assert result == "qux bar qux baz qux"
    end

    test "multiple matches without replace_all returns error" do
      content = "foo bar foo"

      assert {:error, :multiple_matches, 2} =
               SandboxHelpers.apply_edit(content, "foo", "qux")
    end

    test "not found returns error" do
      content = "hello world"

      assert {:error, :not_found, _} =
               SandboxHelpers.apply_edit(content, "xyz", "abc")
    end

    test "matches via quote normalization" do
      # File has curly quotes, model sends straight quotes
      content = "She said \u201Chello\u201D"

      assert {:ok, result, %{replacements: 1}} =
               SandboxHelpers.apply_edit(content, "She said \"hello\"", "She said \"goodbye\"")

      # The curly-quoted original is replaced
      refute String.contains?(result, "\u201Chello\u201D")
    end

    test "matches via trailing whitespace stripping" do
      # File has trailing spaces, model omits them
      content = "def hello   \n  :world  \nend"

      assert {:ok, result, %{replacements: 1}} =
               SandboxHelpers.apply_edit(
                 content,
                 "def hello\n  :world\nend",
                 "def goodbye\n  :earth\nend"
               )

      assert String.contains?(result, "goodbye")
    end

    test "deletion removes trailing newline to avoid blank lines" do
      content = "line1\ndelete_me\nline3"

      assert {:ok, result, %{replacements: 1}} =
               SandboxHelpers.apply_edit(content, "delete_me", "")

      assert result == "line1\nline3"
    end

    test "deletion preserves trailing newline when old_string ends with newline" do
      content = "line1\ndelete_me\nline3"

      assert {:ok, result, %{replacements: 1}} =
               SandboxHelpers.apply_edit(content, "delete_me\n", "")

      assert result == "line1\nline3"
    end
  end
end
