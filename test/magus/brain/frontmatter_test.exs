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

    test "round-trips a multi-line scalar via a double-quoted YAML escape" do
      matter = %{"instructions" => "a\nb"}
      dumped = Frontmatter.dump(matter)

      assert String.starts_with?(dumped, "---\n")
      assert String.ends_with?(dumped, "---\n")
      # Serialized on a single logical line (double-quoted scalar), not a
      # raw newline splitting the YAML mapping entry.
      assert dumped =~ ~s(instructions: "a\\nb")

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      assert parsed["instructions"] == "a\nb"
    end

    test "round-trips a scalar containing backslash, quote, tab, and carriage return" do
      matter = %{"instructions" => "a\\b\"c\td\re"}
      dumped = Frontmatter.dump(matter)

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      assert parsed["instructions"] == "a\\b\"c\td\re"
    end

    test "round-trips a multi-paragraph multi-line scalar (minus one trailing newline)" do
      text = "Section guide:\n\n- Cite sources.\n- Keep entries dated.\n"
      matter = %{"instructions" => text}
      dumped = Frontmatter.dump(matter)

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      # The underlying YAML parser (yamerl, via YamlElixir) normalizes a
      # double-quoted scalar's trailing "\n" escape by dropping exactly one
      # trailing newline on parse (confirmed: "a\nb\n" -> "a\nb", and
      # "a\nb\n\n" -> "a\nb", i.e. always exactly one, not "all trailing
      # newlines"). This is a parser-level normalization, not data loss in
      # dump/1: a value with no trailing newline round-trips byte-for-byte
      # (see the "double-quoted YAML escape" test above), and section-guide
      # prose text has no caller that treats a trailing newline as
      # semantically meaningful.
      expected = binary_part(text, 0, byte_size(text) - 1)
      assert parsed["instructions"] == expected
    end
  end

  describe "dump_value fallback (defensive, via dump/1)" do
    test "serializes a preserved non-scalar/non-list value via to_string/1 instead of crashing" do
      # `created:`/`modified:` keys can carry a Date/DateTime when a page's
      # frontmatter map was built programmatically rather than parsed from
      # YAML text. dump/1 must not crash on these; it should fall back to
      # to_string/1 rather than only handling binary/number/atom/list.
      matter = %{"created" => ~D[2026-01-15]}
      dumped = Frontmatter.dump(matter)

      assert dumped =~ "created: 2026-01-15"
    end

    test "serializes a DateTime value via to_string/1" do
      matter = %{"modified" => ~U[2026-01-15 10:30:00Z]}
      dumped = Frontmatter.dump(matter)

      # to_string/1 on a DateTime yields "2026-01-15 10:30:00Z", which
      # contains a `:` (a YAML special char per dump_scalar's existing
      # quoting rule), so it's quoted like any other scalar containing `:`.
      assert dumped =~ ~s(modified: "2026-01-15 10:30:00Z")

      reparsed_body = dumped <> "body"
      assert {parsed, "body"} = Frontmatter.parse(reparsed_body)
      assert parsed["modified"] == "2026-01-15 10:30:00Z"
    end
  end

  describe "put/3" do
    test "adds a key to a body with no existing frontmatter" do
      body = "# Hello\n\nworld"
      result = Frontmatter.put(body, "instructions", "Be concise.")

      assert {matter, rest} = Frontmatter.parse(result)
      assert matter["instructions"] == "Be concise."
      assert rest == body
    end

    test "overwrites an existing key while preserving other keys" do
      body = "---\ninstructions: Old guide.\ntype: Paper\n---\n# X\n"
      result = Frontmatter.put(body, "instructions", "New guide.")

      assert {matter, rest} = Frontmatter.parse(result)
      assert matter["instructions"] == "New guide."
      assert matter["type"] == "Paper"
      assert rest == "# X\n"
    end

    test "puts a multi-line value into a body that already has type and tags, preserving both" do
      body = "---\ntype: Paper\ntags: [a, b]\n---\n# X\n"
      multi_line = "Line one.\nLine two.\nLine three."

      result = Frontmatter.put(body, "instructions", multi_line)

      assert {matter, rest} = Frontmatter.parse(result)
      assert matter["instructions"] == multi_line
      assert matter["type"] == "Paper"
      assert matter["tags"] == ["a", "b"]
      assert rest == "# X\n"
    end

    test "returns an error tuple rather than corrupting the body when frontmatter is malformed" do
      body = "---\nicon: [unterminated\n---\nx\n"

      assert {:error, :invalid_frontmatter} = Frontmatter.put(body, "instructions", "text")
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
