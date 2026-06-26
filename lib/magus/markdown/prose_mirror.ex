defmodule Magus.Markdown.ProseMirror do
  @moduledoc """
  Converts between Markdown and ProseMirror JSON (TipTap document format).

  Uses MDEx to parse markdown into an AST, then walks the AST to produce
  ProseMirror-compatible JSON maps with string keys. Also provides reverse
  conversions: JSON → markdown and JSON → plain text.

  ## Profiles

  Domain-specific node lifting/serialization is delegated to a
  `Magus.Markdown.ProseMirror.Profile`. The default profile is a no-op, so
  only standard markdown shapes are produced. A custom profile can lift
  fenced code blocks (or other shapes) into domain-specific ProseMirror
  nodes via `post_process/1`, and serialize those nodes back to markdown via
  `node_to_markdown/1`. Pass `profile: MyProfile` to `from_markdown/2` and
  `to_markdown/2`.

  ## ProseMirror JSON structure

  Documents are nested maps with string keys:

      %{"type" => "doc", "content" => [
        %{"type" => "paragraph", "content" => [
          %{"type" => "text", "text" => "Hello "},
          %{"type" => "text", "text" => "world", "marks" => [%{"type" => "bold"}]}
        ]}
      ]}

  Inline formatting (bold, italic, links, etc.) is represented as "marks"
  on text nodes rather than as nested elements.
  """

  alias Magus.Markdown.ProseMirror.Profile

  @mdex_extensions [
    table: true,
    tasklist: true,
    strikethrough: true
  ]

  @doc """
  Converts a markdown string to a ProseMirror JSON document.

  Returns `{:ok, map()}` with a valid ProseMirror document, or
  `{:error, term()}` if parsing fails.

  Accepts a `:profile` option (defaults to
  `Magus.Markdown.ProseMirror.Profile.Default`) whose `post_process/1` runs
  on the resulting document, allowing domain-specific node lifting.
  """
  @spec from_markdown(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_markdown(markdown, opts \\ []) when is_binary(markdown) do
    profile = Keyword.get(opts, :profile, Profile.Default)
    markdown = String.trim(markdown)

    if markdown == "" do
      {:ok, default_doc()}
    else
      case MDEx.parse_document(markdown, extension: @mdex_extensions) do
        {:ok, doc} ->
          content = convert_nodes(doc.nodes)
          content = if content == [], do: [%{"type" => "paragraph"}], else: content
          doc = %{"type" => "doc", "content" => content}
          {:ok, profile.post_process(doc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Converts a ProseMirror JSON document to a markdown string.

  This function must be **deterministic** — the same JSON input always
  produces the same markdown output. This property is relied upon by
  the NodeReplacer for surgical text matching.

  Accepts a `:profile` option (defaults to
  `Magus.Markdown.ProseMirror.Profile.Default`) whose `node_to_markdown/1`
  is consulted for each node before falling back to the standard
  serialization, allowing domain-specific node serialization.
  """
  @spec to_markdown(map(), keyword()) :: String.t()
  def to_markdown(doc, opts \\ [])

  def to_markdown(%{"type" => "doc", "content" => content}, opts) when is_list(content) do
    profile = Keyword.get(opts, :profile, Profile.Default)

    content
    |> Enum.map(&node_to_markdown(&1, profile))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  def to_markdown(%{"type" => "doc"}, _opts), do: ""
  def to_markdown(_, _opts), do: ""

  @doc """
  Converts a ProseMirror JSON document to plain text (no formatting).

  Block elements are separated by newlines. Used for display purposes
  where formatting is not needed.
  """
  @spec to_plain_text(map()) :: String.t()
  def to_plain_text(%{"type" => "doc", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&node_to_plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def to_plain_text(%{"type" => "doc"}), do: ""
  def to_plain_text(_), do: ""

  @doc """
  Returns an empty ProseMirror document.
  """
  @spec default_doc() :: map()
  def default_doc do
    %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
  end

  # ---------------------------------------------------------------------------
  # MDEx AST → ProseMirror JSON
  # ---------------------------------------------------------------------------

  defp convert_nodes(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &convert_node/1)
  end

  # Block nodes

  defp convert_node(%MDEx.Paragraph{nodes: children}) do
    content = convert_inline_nodes(children, [])
    [%{"type" => "paragraph"} |> maybe_add_content(content)]
  end

  defp convert_node(%MDEx.Heading{level: level, nodes: children}) do
    content = convert_inline_nodes(children, [])

    [
      %{"type" => "heading", "attrs" => %{"level" => level}}
      |> maybe_add_content(content)
    ]
  end

  defp convert_node(%MDEx.CodeBlock{info: info, literal: literal}) do
    language = if info != "" and info != nil, do: info, else: nil
    text_content = String.trim_trailing(literal, "\n")

    node = %{"type" => "codeBlock"}
    node = if language, do: Map.put(node, "attrs", %{"language" => language}), else: node

    node =
      if text_content != "" do
        Map.put(node, "content", [%{"type" => "text", "text" => text_content}])
      else
        node
      end

    [node]
  end

  defp convert_node(%MDEx.BlockQuote{nodes: children}) do
    content = convert_nodes(children)
    [%{"type" => "blockquote", "content" => content}]
  end

  defp convert_node(%MDEx.List{list_type: list_type, nodes: children}) do
    has_task_items = Enum.any?(children, &match?(%MDEx.TaskItem{}, &1))

    type =
      cond do
        has_task_items -> "taskList"
        list_type == :bullet -> "bulletList"
        true -> "orderedList"
      end

    content = convert_nodes(children)
    [%{"type" => type, "content" => content}]
  end

  defp convert_node(%MDEx.ListItem{nodes: children}) do
    content = convert_nodes(children)
    [%{"type" => "listItem", "content" => content}]
  end

  defp convert_node(%MDEx.TaskItem{checked: checked, nodes: children}) do
    content = convert_nodes(children)
    [%{"type" => "taskItem", "attrs" => %{"checked" => checked}, "content" => content}]
  end

  defp convert_node(%MDEx.Table{nodes: rows}) do
    content = convert_nodes(rows)
    [%{"type" => "table", "content" => content}]
  end

  defp convert_node(%MDEx.TableRow{header: header, nodes: cells}) do
    content =
      Enum.flat_map(cells, fn cell ->
        cell_type = if header, do: "tableHeader", else: "tableCell"
        cell_content = convert_inline_nodes(cell.nodes, [])
        # Wrap inline content in a paragraph (ProseMirror tables require block content in cells)
        inner =
          if cell_content == [],
            do: [%{"type" => "paragraph"}],
            else: [%{"type" => "paragraph", "content" => cell_content}]

        [
          %{
            "type" => cell_type,
            "attrs" => %{"colspan" => 1, "rowspan" => 1},
            "content" => inner
          }
        ]
      end)

    [%{"type" => "tableRow", "content" => content}]
  end

  defp convert_node(%MDEx.ThematicBreak{}) do
    [%{"type" => "horizontalRule"}]
  end

  defp convert_node(%MDEx.HtmlBlock{literal: literal}) do
    # Treat raw HTML blocks as paragraphs with the HTML as text
    if String.trim(literal) == "" do
      []
    else
      [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "text" => String.trim(literal)}]
        }
      ]
    end
  end

  # Inline nodes that appear at block level (shouldn't happen, but handle gracefully)
  defp convert_node(%MDEx.Text{} = node) do
    convert_inline_nodes([node], [])
  end

  defp convert_node(_unknown), do: []

  # ---------------------------------------------------------------------------
  # Inline nodes with mark accumulation
  # ---------------------------------------------------------------------------

  defp convert_inline_nodes(nodes, marks) when is_list(nodes) do
    Enum.flat_map(nodes, &convert_inline_node(&1, marks))
  end

  defp convert_inline_node(%MDEx.Text{literal: literal}, marks) do
    node = %{"type" => "text", "text" => literal}
    [maybe_add_marks(node, marks)]
  end

  defp convert_inline_node(%MDEx.Strong{nodes: children}, marks) do
    convert_inline_nodes(children, marks ++ [%{"type" => "bold"}])
  end

  defp convert_inline_node(%MDEx.Emph{nodes: children}, marks) do
    convert_inline_nodes(children, marks ++ [%{"type" => "italic"}])
  end

  defp convert_inline_node(%MDEx.Strikethrough{nodes: children}, marks) do
    convert_inline_nodes(children, marks ++ [%{"type" => "strike"}])
  end

  defp convert_inline_node(%MDEx.Link{url: url, nodes: children}, marks) do
    link_mark = %{"type" => "link", "attrs" => %{"href" => url}}
    convert_inline_nodes(children, marks ++ [link_mark])
  end

  defp convert_inline_node(%MDEx.Code{literal: literal}, marks) do
    node = %{"type" => "text", "text" => literal}
    [maybe_add_marks(node, marks ++ [%{"type" => "code"}])]
  end

  defp convert_inline_node(%MDEx.Image{url: url, title: title, nodes: children}, _marks) do
    alt = extract_text_from_nodes(children)

    attrs = %{"src" => url}
    attrs = if alt != "", do: Map.put(attrs, "alt", alt), else: attrs
    attrs = if title != "" and title != nil, do: Map.put(attrs, "title", title), else: attrs

    [%{"type" => "image", "attrs" => attrs}]
  end

  defp convert_inline_node(%MDEx.SoftBreak{}, marks) do
    # Soft breaks become spaces in ProseMirror (normal paragraph flow)
    node = %{"type" => "text", "text" => " "}
    [maybe_add_marks(node, marks)]
  end

  defp convert_inline_node(%MDEx.LineBreak{}, _marks) do
    [%{"type" => "hardBreak"}]
  end

  defp convert_inline_node(%MDEx.HtmlInline{literal: literal}, marks) do
    # Treat inline HTML as plain text
    node = %{"type" => "text", "text" => literal}
    [maybe_add_marks(node, marks)]
  end

  defp convert_inline_node(_unknown, _marks), do: []

  # ---------------------------------------------------------------------------
  # ProseMirror JSON → Markdown
  # ---------------------------------------------------------------------------

  defp node_to_markdown(node, profile) do
    case profile.node_to_markdown(node) do
      {:ok, md} -> md
      :default -> node_to_markdown_default(node, profile)
    end
  end

  defp node_to_markdown_default(%{"type" => "paragraph", "content" => content}, profile) do
    inline_to_markdown(content, profile)
  end

  defp node_to_markdown_default(%{"type" => "paragraph"}, _profile), do: ""

  defp node_to_markdown_default(
         %{
           "type" => "heading",
           "attrs" => %{"level" => level},
           "content" => content
         },
         profile
       ) do
    prefix = String.duplicate("#", coerce_heading_level(level))
    "#{prefix} #{inline_to_markdown(content, profile)}"
  end

  defp node_to_markdown_default(%{"type" => "heading", "attrs" => %{"level" => level}}, _profile),
    do: String.duplicate("#", coerce_heading_level(level))

  defp node_to_markdown_default(
         %{
           "type" => "codeBlock",
           "attrs" => %{"language" => lang},
           "content" => [%{"text" => text}]
         },
         _profile
       ) do
    "```#{lang || ""}\n#{text}\n```"
  end

  defp node_to_markdown_default(
         %{"type" => "codeBlock", "content" => [%{"text" => text}]},
         _profile
       ) do
    "```\n#{text}\n```"
  end

  defp node_to_markdown_default(%{"type" => "codeBlock"}, _profile), do: "```\n```"

  defp node_to_markdown_default(%{"type" => "blockquote", "content" => content}, profile) do
    content
    |> Enum.map(&node_to_markdown(&1, profile))
    |> Enum.join("\n\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp node_to_markdown_default(%{"type" => "bulletList", "content" => items}, profile) do
    items
    |> Enum.map_join("\n", &list_item_to_markdown(&1, "- ", profile))
  end

  defp node_to_markdown_default(%{"type" => "taskList", "content" => items}, profile) do
    items
    |> Enum.map_join("\n", &node_to_markdown(&1, profile))
  end

  defp node_to_markdown_default(%{"type" => "orderedList", "content" => items}, profile) do
    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, idx} ->
      list_item_to_markdown(item, "#{idx}. ", profile)
    end)
  end

  defp node_to_markdown_default(
         %{
           "type" => "taskItem",
           "attrs" => %{"checked" => checked},
           "content" => content
         },
         profile
       ) do
    checkbox = if checked, do: "[x]", else: "[ ]"
    text = content |> Enum.map(&node_to_markdown(&1, profile)) |> Enum.join("\n")
    "- #{checkbox} #{text}"
  end

  defp node_to_markdown_default(%{"type" => "table", "content" => rows}, profile) do
    rows_md = Enum.map(rows, &table_row_to_markdown(&1, profile))

    case rows_md do
      [header | rest] ->
        cols = header |> String.split("|") |> Enum.reject(&(&1 == "")) |> length()
        separator = "| " <> (1..max(cols, 1) |> Enum.map_join(" | ", fn _ -> "---" end)) <> " |"
        Enum.join([header, separator | rest], "\n")

      [] ->
        ""
    end
  end

  defp node_to_markdown_default(%{"type" => "horizontalRule"}, _profile), do: "---"

  defp node_to_markdown_default(%{"type" => "image", "attrs" => attrs}, _profile) do
    src = attrs["src"] || ""
    alt = attrs["alt"] || ""
    "![#{alt}](#{src}#{image_title_suffix(attrs)})"
  end

  defp node_to_markdown_default(%{"type" => "hardBreak"}, _profile), do: "  \n"

  defp node_to_markdown_default(_, _profile), do: ""

  defp list_item_to_markdown(%{"type" => type, "content" => content}, prefix, profile)
       when type in ["listItem", "taskItem"] do
    case content do
      [first | rest] ->
        first_line = node_to_markdown(first, profile)
        indent = String.duplicate(" ", String.length(prefix))

        rest_lines =
          rest
          |> Enum.map(&node_to_markdown(&1, profile))
          |> Enum.map_join("\n", fn line ->
            line
            |> String.split("\n")
            |> Enum.map_join("\n", &(indent <> &1))
          end)

        if rest_lines == "" do
          "#{prefix}#{first_line}"
        else
          "#{prefix}#{first_line}\n#{rest_lines}"
        end

      [] ->
        prefix
    end
  end

  defp list_item_to_markdown(
         %{"type" => "taskItem", "attrs" => %{"checked" => checked}, "content" => content},
         _prefix,
         profile
       ) do
    checkbox = if checked, do: "[x]", else: "[ ]"
    text = content |> Enum.map(&node_to_markdown(&1, profile)) |> Enum.join("\n")
    "- #{checkbox} #{text}"
  end

  defp list_item_to_markdown(_, prefix, _profile), do: prefix

  defp table_row_to_markdown(%{"type" => "tableRow", "content" => cells}, profile) do
    cells_md =
      Enum.map(cells, fn cell ->
        content = cell["content"] || []

        content
        |> Enum.map(fn
          %{"type" => "paragraph", "content" => inline} -> inline_to_markdown(inline, profile)
          %{"type" => "paragraph"} -> ""
          other -> node_to_markdown(other, profile)
        end)
        |> Enum.join(" ")
        |> String.trim()
      end)

    "| " <> Enum.join(cells_md, " | ") <> " |"
  end

  # Inline serialization uses a mark STACK (ported from prosemirror-markdown's
  # `MarkdownSerializerState.renderInline`). Each text node carries its own
  # marks, but MDEx splits a single bold/italic run that contains a code span or
  # a link into several adjacent text nodes that each repeat the outer mark. If
  # we wrapped every node independently the delimiters would be re-emitted at
  # every boundary (e.g. `**a `b` c**` -> `**a **`**b**`** c**`) and grow on
  # each save. Instead we track the marks currently open, and at each node only
  # close the marks that are no longer active and open the newly-active ones,
  # emitting delimiters at run boundaries only.
  #
  # Marks are normalized so the nesting is deterministic AND keeps a mark that is
  # already open continuous across adjacent nodes (the reference's "mixable"
  # reordering). For each node we put marks that are already in `active` first,
  # in `active`'s order (so e.g. an outer italic stays open across an inner
  # link), then append the rest in a fixed canonical rank
  # (link < bold < italic < strike < code) for the first/default ordering.
  defp inline_to_markdown(nodes, profile) when is_list(nodes) do
    {out, active} =
      Enum.reduce(nodes, {"", []}, fn node, {acc, active} ->
        marks = normalized_marks(node, active)
        keep = common_prefix_length(active, marks)

        # Close marks no longer active, in reverse (innermost first).
        acc = close_marks(acc, Enum.reverse(Enum.drop(active, keep)))
        # Open newly-active marks, in order (outermost first).
        acc = open_marks(acc, Enum.drop(marks, keep))
        # Emit the node body (text as-is, atoms with no marks).
        acc = acc <> inline_node_body(node, profile)

        {acc, marks}
      end)

    # Close any marks still open at the end, innermost first.
    close_marks(out, Enum.reverse(active))
  end

  # The marks open around a node, in canonical nesting order, given the marks
  # currently `active`. Atoms (images, profile atoms like pageRef/tag/
  # messageBlock) carry no marks.
  defp normalized_marks(%{"type" => "text"} = node, active),
    do: order_marks(node["marks"] || [], active)

  defp normalized_marks(_node, _active), do: []

  # Order a node's marks: keep marks already open (present in `active`) first in
  # `active`'s relative order so continuous marks stay open and the common prefix
  # with `active` is maximized; append the remaining (newly opened) marks in a
  # fixed canonical rank. Each entry is the canonical mark map (so a link keeps
  # its href attrs for the close delimiter). Unknown mark types are dropped.
  @mark_order %{"link" => 0, "bold" => 1, "italic" => 2, "strike" => 3, "code" => 4}

  defp order_marks(marks, active) do
    known = Enum.filter(marks, &Map.has_key?(@mark_order, &1["type"]))

    {in_active, fresh} =
      Enum.split_with(known, fn mark -> Enum.any?(active, &marks_equal?(&1, mark)) end)

    # Preserve active's order for the already-open marks.
    kept = Enum.filter(active, fn a -> Enum.any?(in_active, &marks_equal?(a, &1)) end)
    kept ++ Enum.sort_by(fresh, &@mark_order[&1["type"]])
  end

  # Longest common prefix length of two ordered mark lists. Marks are equal when
  # they serialize identically (type + relevant attrs), so a link with the same
  # href stays open across adjacent nodes.
  defp common_prefix_length([a | as], [b | bs]) do
    if marks_equal?(a, b), do: 1 + common_prefix_length(as, bs), else: 0
  end

  defp common_prefix_length(_, _), do: 0

  defp marks_equal?(%{"type" => "link"} = a, %{"type" => "link"} = b) do
    link_href(a) == link_href(b)
  end

  defp marks_equal?(%{"type" => t}, %{"type" => t}), do: true
  defp marks_equal?(_, _), do: false

  defp open_marks(acc, marks), do: Enum.reduce(marks, acc, &(&2 <> mark_open(&1)))

  defp close_marks(acc, marks), do: Enum.reduce(marks, acc, &(&2 <> mark_close(&1)))

  defp mark_open(%{"type" => "bold"}), do: "**"
  defp mark_open(%{"type" => "italic"}), do: "*"
  defp mark_open(%{"type" => "strike"}), do: "~~"
  defp mark_open(%{"type" => "code"}), do: "`"
  defp mark_open(%{"type" => "link"}), do: "["

  defp mark_close(%{"type" => "bold"}), do: "**"
  defp mark_close(%{"type" => "italic"}), do: "*"
  defp mark_close(%{"type" => "strike"}), do: "~~"
  defp mark_close(%{"type" => "code"}), do: "`"
  defp mark_close(%{"type" => "link"} = mark), do: "](#{link_href(mark)})"

  defp link_href(%{"attrs" => %{"href" => href}}), do: href
  defp link_href(_), do: ""

  # The body of an inline node WITHOUT its marks. Profile atoms (pageRef, tag,
  # messageBlock, ...) are consulted first and emit their own string; they carry
  # no marks. Text is emitted as-is (no markdown escaping in this task).
  defp inline_node_body(node, profile) do
    case profile.inline_node_to_markdown(node) do
      {:ok, md} -> md
      :default -> inline_node_body_default(node)
    end
  end

  defp inline_node_body_default(%{"type" => "text", "text" => text}), do: text
  defp inline_node_body_default(%{"type" => "hardBreak"}), do: "  \n"

  defp inline_node_body_default(%{"type" => "image", "attrs" => attrs}) do
    src = attrs["src"] || ""
    alt = attrs["alt"] || ""
    "![#{alt}](#{src}#{image_title_suffix(attrs)})"
  end

  defp inline_node_body_default(_), do: ""

  # ` "title"` suffix for an image, emitted only when a non-empty title is set.
  defp image_title_suffix(%{"title" => title}) when is_binary(title) and title != "" do
    ~s( "#{title}")
  end

  defp image_title_suffix(_), do: ""

  # ---------------------------------------------------------------------------
  # ProseMirror JSON → Plain Text
  # ---------------------------------------------------------------------------

  defp node_to_plain_text(%{"type" => "paragraph", "content" => content}) do
    extract_text(content)
  end

  defp node_to_plain_text(%{"type" => "paragraph"}), do: ""

  defp node_to_plain_text(%{"type" => "heading", "content" => content}) do
    extract_text(content)
  end

  defp node_to_plain_text(%{"type" => "heading"}), do: ""

  defp node_to_plain_text(%{"type" => "codeBlock", "content" => [%{"text" => text}]}) do
    text
  end

  defp node_to_plain_text(%{"type" => "codeBlock"}), do: ""

  defp node_to_plain_text(%{"type" => "blockquote", "content" => content}) do
    content
    |> Enum.map(&node_to_plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp node_to_plain_text(%{"type" => type, "content" => items})
       when type in ["bulletList", "orderedList", "taskList"] do
    items
    |> Enum.map(&node_to_plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp node_to_plain_text(%{"type" => type, "content" => content})
       when type in ["listItem", "taskItem"] do
    content
    |> Enum.map(&node_to_plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp node_to_plain_text(%{"type" => "table", "content" => rows}) do
    rows
    |> Enum.map(fn %{"content" => cells} ->
      cells
      |> Enum.map(fn cell ->
        (cell["content"] || [])
        |> Enum.map(&node_to_plain_text/1)
        |> Enum.join(" ")
        |> String.trim()
      end)
      |> Enum.join(" | ")
    end)
    |> Enum.join("\n")
  end

  defp node_to_plain_text(%{"type" => "horizontalRule"}), do: "---"

  defp node_to_plain_text(%{"type" => "image", "attrs" => attrs}) do
    attrs["alt"] || ""
  end

  defp node_to_plain_text(_), do: ""

  defp extract_text(nodes) when is_list(nodes) do
    Enum.map_join(nodes, "", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "hardBreak"} -> "\n"
      _ -> ""
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp maybe_add_content(node, []), do: node
  defp maybe_add_content(node, content), do: Map.put(node, "content", content)

  defp maybe_add_marks(node, []), do: node
  defp maybe_add_marks(node, marks), do: Map.put(node, "marks", marks)

  defp extract_text_from_nodes(nodes) when is_list(nodes) do
    Enum.map_join(nodes, "", fn
      %MDEx.Text{literal: literal} -> literal
      _ -> ""
    end)
  end

  defp extract_text_from_nodes(_), do: ""

  defp coerce_heading_level(level) when is_integer(level) and level >= 1, do: level

  defp coerce_heading_level(level) when is_binary(level) do
    case Integer.parse(level) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp coerce_heading_level(level) when is_float(level) and level >= 1, do: trunc(level)
  defp coerce_heading_level(_), do: 1
end
