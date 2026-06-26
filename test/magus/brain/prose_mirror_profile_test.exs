defmodule Magus.Brain.ProseMirrorProfileTest do
  use ExUnit.Case, async: true
  alias Magus.Markdown.ProseMirror
  @profile Magus.Brain.ProseMirrorProfile

  defp doc(md), do: elem(ProseMirror.from_markdown(md, profile: @profile), 1)

  test "callout fence lifts to calloutBlock" do
    node = doc("```callout\nvariant: note\ntext: hello\n```")["content"] |> hd()
    assert node["type"] == "calloutBlock"
    assert node["attrs"]["variant"] == "note"
    assert node["attrs"]["text"] == "hello"
  end

  test "source fence lifts to sourceBlock" do
    node =
      doc("```source\nurl: https://x.com\ntitle: X\nsource_type: web\n```")["content"] |> hd()

    assert node["type"] == "sourceBlock"
    assert node["attrs"]["url"] == "https://x.com"
    assert node["attrs"]["title"] == "X"
  end

  test "magus image paragraph lifts to imageBlock" do
    node = doc("![cap](magus://image/abc12345)")["content"] |> hd()
    assert node["type"] == "imageBlock"
    assert node["attrs"]["fileId"] == "abc12345"
    assert node["attrs"]["caption"] == "cap"
  end

  test "magus file link lifts to fileBlock" do
    node = doc("[📎 notes.pdf](magus://file/def67890)")["content"] |> hd()
    assert node["type"] == "fileBlock"
    assert node["attrs"]["fileId"] == "def67890"
    assert node["attrs"]["caption"] == "notes.pdf"
  end

  test "wikilink + tag lift to inline atoms" do
    para = doc("See [[Other Page]] about #ml")["content"] |> hd()
    types = Enum.map(para["content"], & &1["type"])
    assert "pageRef" in types
    assert "tag" in types

    assert Enum.find(para["content"], &(&1["type"] == "pageRef"))["attrs"]["title"] ==
             "Other Page"

    assert Enum.find(para["content"], &(&1["type"] == "tag"))["attrs"]["name"] == "ml"
  end

  test "message ref lifts to messageBlock" do
    node = doc("[[msg:11112222|hi there]]")["content"] |> hd()
    ref = if node["type"] == "messageBlock", do: node, else: hd(node["content"])
    assert ref["type"] == "messageBlock"
    assert ref["attrs"]["messageId"] == "11112222"
    assert ref["attrs"]["previewText"] == "hi there"
  end

  @cases [
    "```callout\nvariant: note\ntext: hello\n```",
    # URL is quoted because it contains ":" — this is the canonical form all
    # three writers (Elixir BlockSerializer, this profile, the JS editor's
    # escapeYamlScalar) emit. The unquoted form is non-canonical input that no
    # writer produces, so it cannot be a round-trip fixed point.
    "```source\nurl: \"https://x.com\"\ntitle: X\nsource_type: web\n```",
    "![cap](magus://image/abc12345)",
    "[📎 notes.pdf](magus://file/def67890)",
    "[[msg:11112222|hi there]]",
    "See [[Other Page]] about #ml",
    "- [ ] todo\n- [x] done"
  ]

  test "brain constructs round-trip losslessly" do
    for md <- @cases do
      {:ok, d} = ProseMirror.from_markdown(md, profile: @profile)
      assert ProseMirror.to_markdown(d, profile: @profile) == md, "round-trip drift for: #{md}"
    end
  end

  test "frontmatter is split on load and re-attached on save" do
    body = "---\nicon: 🧠\ntags: [ml]\n---\n# Title\n\nbody"
    {fm, rest} = Magus.Brain.ProseMirrorProfile.split_frontmatter(body)
    assert fm == "---\nicon: 🧠\ntags: [ml]\n---\n"
    assert String.starts_with?(rest, "# Title")

    {:ok, d} = ProseMirror.from_markdown(rest, profile: @profile)

    rebuilt =
      Magus.Brain.ProseMirrorProfile.reattach_frontmatter(
        fm,
        ProseMirror.to_markdown(d, profile: @profile)
      )

    assert rebuilt == body
  end

  test "no frontmatter is a no-op" do
    assert {"", "# Hi"} = Magus.Brain.ProseMirrorProfile.split_frontmatter("# Hi")
  end

  test "representative page bodies survive load->save unchanged" do
    bodies = [
      "# Heading\n\nA paragraph with **bold** and a [[Wiki Link]].",
      "- a\n- b\n  - nested",
      "```elixir\nIO.puts(:hi)\n```",
      "```callout\nvariant: warning\ntext: |\n  line one\n  line two\n```",
      "Tag soup #ml #ai and a #note",
      "---\ntags: [x]\n---\n- [ ] todo",
      # Blockquote on a single line. A soft-wrapped multi-line quote
      # ("> a\n> b") canonicalizes to one line here because a CommonMark soft
      # break renders as a space and ProseMirror has no node for an intra-
      # paragraph line wrap (MDEx.SoftBreak -> a " " text node) — the same
      # canonicalization the converter applies to every soft-wrapped paragraph,
      # not a blockquote-specific loss. Separate paragraphs ("> a\n>\n> b") and
      # hard breaks ("a  \nb") both survive; only the cosmetic wrap normalizes.
      "> a quote on one line"
    ]

    for body <- bodies do
      {fm, rest} = Magus.Brain.ProseMirrorProfile.split_frontmatter(body)

      {:ok, d} =
        Magus.Markdown.ProseMirror.from_markdown(rest, profile: Magus.Brain.ProseMirrorProfile)

      out =
        Magus.Brain.ProseMirrorProfile.reattach_frontmatter(
          fm,
          Magus.Markdown.ProseMirror.to_markdown(d, profile: Magus.Brain.ProseMirrorProfile)
        )

      assert out == body, "drift for:\n#{body}\n---got---\n#{out}"
    end
  end
end
