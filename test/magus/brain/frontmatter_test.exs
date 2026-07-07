defmodule Magus.Brain.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Magus.Brain.Frontmatter

  describe "parse/1" do
    test "returns empty map and unchanged body when no frontmatter present" do
      assert {%{}, "# Hello\n\nworld"} = Frontmatter.parse("# Hello\n\nworld")
    end

    test "parses a well-formed frontmatter block" do
      body = """
      ---
      icon: 🧠
      tags: [ml, research]
      ---
      # Page
      """

      assert {matter, rest} = Frontmatter.parse(body)
      assert matter["icon"] == "🧠"
      assert matter["tags"] == ["ml", "research"]
      assert rest == "# Page\n"
    end

    test "normalizes tags to lowercase with hyphens" do
      body = """
      ---
      tags: [Machine Learning, RESEARCH]
      ---
      x
      """

      assert {%{"tags" => tags}, _} = Frontmatter.parse(body)
      assert "machine-learning" in tags
      assert "research" in tags
    end

    test "preserves unknown keys opaquely" do
      body = """
      ---
      icon: 🧠
      custom_field: anything
      ---
      x
      """

      assert {matter, _} = Frontmatter.parse(body)
      assert matter["custom_field"] == "anything"
    end

    test "normalizes aliases as a list, preserving case (unlike tags)" do
      body = """
      ---
      aliases: [Old Name, "Older: Name"]
      ---
      x
      """

      assert {%{"aliases" => aliases}, _} = Frontmatter.parse(body)
      assert "Old Name" in aliases
      assert "Older: Name" in aliases
    end

    test "splits a comma-separated aliases string into a list" do
      body = """
      ---
      aliases: "Foo, Bar, Baz"
      ---
      x
      """

      assert {%{"aliases" => aliases}, _} = Frontmatter.parse(body)
      assert aliases == ["Foo", "Bar", "Baz"]
    end

    test "deduplicates aliases" do
      body = """
      ---
      aliases: [Foo, Foo, Bar]
      ---
      x
      """

      assert {%{"aliases" => aliases}, _} = Frontmatter.parse(body)
      assert aliases == ["Foo", "Bar"]
    end

    test "drops an empty aliases list (put_if_present behavior)" do
      body = """
      ---
      aliases: []
      icon: 🧠
      ---
      x
      """

      assert {matter, _} = Frontmatter.parse(body)
      refute Map.has_key?(matter, "aliases")
      assert matter["icon"] == "🧠"
    end

    test "treats a single leading --- (horizontal rule) as body, not frontmatter" do
      body = "---\n\nJust a horizontal rule then text"
      assert {%{}, ^body} = Frontmatter.parse(body)
    end

    test "returns error tuple on malformed frontmatter that looks like an attempt" do
      body = """
      ---
      icon: [unterminated
      ---
      x
      """

      assert {:error, :invalid_frontmatter} = Frontmatter.parse(body)
    end

    test "handles a frontmatter block whose body parses to nil (YAML comments only)" do
      # YamlFrontMatter parses `# comment` to nil; normalize_known_keys/1
      # must accept nil so the migration worker doesn't blow up on these
      # production pages.
      body = "---\n# just a comment\n---\n# Real heading\n"
      assert {%{}, "# Real heading\n"} = Frontmatter.parse(body)
    end

    test "ignores `---` that appears mid-body (e.g. GFM table separators)" do
      # Markdown table separators (`| --- |`) and horizontal rules below the
      # first line must NOT be picked up as a frontmatter delimiter, even
      # though a naive YAML scan would find a `---`-bounded region.
      body =
        "# Heading\n\nSome text\n\n| col | col |\n| --- | --- |\n| a | b |\n"

      assert {%{}, ^body} = Frontmatter.parse(body)
    end

    test "normalizes type and instructions to trimmed strings" do
      body = "---\ntype: Paper\ninstructions: One paper per page.\n---\n# X\n"

      assert {matter, _rest} = Frontmatter.parse(body)
      assert matter == %{"type" => "Paper", "instructions" => "One paper per page."}
    end

    test "drops a blank type" do
      body = "---\ntype: \"  \"\nicon: 🧠\n---\nx\n"

      assert {matter, _rest} = Frontmatter.parse(body)
      refute Map.has_key?(matter, "type")
      assert matter["icon"] == "🧠"
    end
  end

  describe "normalize_known_keys/1" do
    test "returns an empty map for nil input" do
      assert Frontmatter.normalize_known_keys(nil) == %{}
    end

    test "returns an empty map for non-map scalar input (string, integer, atom)" do
      # YAML can parse a fenced `---` block to any value, not just a map.
      # Treat unmappable shapes as no frontmatter rather than crashing.
      assert Frontmatter.normalize_known_keys("") == %{}
      assert Frontmatter.normalize_known_keys("just a scalar") == %{}
      assert Frontmatter.normalize_known_keys(42) == %{}
      assert Frontmatter.normalize_known_keys([:a, :b]) == %{}
    end

    test "passes through unknown keys for a populated map" do
      assert Frontmatter.normalize_known_keys(%{"x" => 1}) == %{"x" => 1}
    end
  end

  describe "dump/1" do
    test "returns empty string for empty map" do
      assert Frontmatter.dump(%{}) == ""
    end

    test "round-trips a known-keys map" do
      matter = %{"icon" => "🧠", "tags" => ["ml", "research"]}
      dumped = Frontmatter.dump(matter)

      assert String.starts_with?(dumped, "---\n")
      assert String.ends_with?(dumped, "---\n")

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      assert parsed["icon"] == "🧠"
      assert parsed["tags"] == ["ml", "research"]
    end

    test "quotes list items containing YAML-special characters" do
      matter = %{"aliases" => ["Old: Name", "Has, Comma"]}
      dumped = Frontmatter.dump(matter)

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      assert "Old: Name" in parsed["aliases"]
      assert "Has, Comma" in parsed["aliases"]
    end

    test "rejects atom keys with ArgumentError" do
      assert_raise ArgumentError, ~r/string keys/, fn ->
        Frontmatter.dump(%{icon: "🧠"})
      end
    end
  end

  describe "normalize_tag/1" do
    test "lowercases and replaces whitespace with hyphens" do
      assert Frontmatter.normalize_tag("Machine Learning") == "machine-learning"
      assert Frontmatter.normalize_tag("  spaces  ") == "spaces"
      assert Frontmatter.normalize_tag("RESEARCH") == "research"
    end
  end
end
