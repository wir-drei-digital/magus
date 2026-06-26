defmodule Magus.Brain.ProseMirrorProfile do
  @moduledoc """
  `Magus.Markdown.ProseMirror.Profile` for Brain pages.

  Brain page bodies are standard markdown plus a handful of custom shapes
  emitted by `Magus.Brain.BlockSerializer`:

      Image:      ![alt](magus://image/<file_id>)
      File:       [📎 caption](magus://file/<file_id>)
      Callout:    ```callout … ``` fenced block
      Source:     ```source … ``` fenced block
      Wikilink:   [[Page Title]]
      MessageRef: [[msg:<message_id>|preview]]
      Tag:        #tag-name

  `post_process/1` handles the markdown → ProseMirror lifting; `node_to_markdown/1`
  and `inline_node_to_markdown/1` handle the reverse ProseMirror → markdown
  serialization (ported byte-for-byte from `Magus.Brain.BlockSerializer`).

  For lifting, the core `Magus.Markdown.ProseMirror` converter first produces a
  standard PM JSON document (callouts/sources arrive as `codeBlock`, the
  magus links/images as ordinary `paragraph`/`image`/`link` shapes, and the
  inline `[[..]]`/`#tag` patterns as plain text). `post_process/1` then walks
  that document and lifts those shapes into the Brain-specific node types:
  `calloutBlock`, `sourceBlock`, `imageBlock`, `fileBlock`, `pageRef`,
  `messageBlock`, and `tag`.

  It is a pure function over maps with string keys — no DB, no IO. It mirrors
  `transformBlock`/`splitTextForAtoms` in `assets/js/lib/brain_markdown.js` so
  the server-side and client-side conversions agree.

  Custom-node attribute names are **camelCase** (`fileId`, `sourceType`,
  `messageId`, `previewText`) to match the TipTap node schemas in
  `assets/js/extensions/brain_blocks.js` — the PM JSON this produces is fed
  straight into the editor, so the attr keys must match what each NodeView
  reads. Editor-only attrs with schema defaults (`ingested`, `ingestionError`,
  `contributorType`) are omitted; ProseMirror fills their defaults on load.
  """

  @behaviour Magus.Markdown.ProseMirror.Profile

  # Regexes mirror the lifting patterns in `assets/js/lib/brain_markdown.js`
  # (`transformBlock`/`splitTextForAtoms`) so the server-side and client-side
  # conversions agree. The id patterns are intentionally the permissive `{8,}`
  # hex/hyphen form used by `transformBlock` (UUIDs and ULIDs both match); the
  # stricter `Magus.Brain.BodyParser` patterns drive index derivation from the
  # already-serialized body, which is a separate concern.
  @magus_image_re ~r/^magus:\/\/image\/([0-9a-fA-F-]{8,})$/
  @magus_file_re ~r/^magus:\/\/file\/([0-9a-fA-F-]{8,})$/
  @wikilink_re ~r/\[\[([^\[\]\n]+)\]\]/
  @msg_ref_re ~r/^msg:([0-9a-fA-F-]{8,})(?:\|(.*))?$/
  # Group 1 = leading boundary (start-of-string or whitespace), group 2 = tag.
  @tag_re ~r/(^|\s)#([a-z0-9][a-z0-9_-]*)/i

  # File caption strips a leading "📎 " prefix (the attachment glyph).
  @paperclip "\u{1F4CE}"

  @impl true
  def post_process(%{"content" => content} = doc) when is_list(content) do
    %{doc | "content" => transform_blocks(content)}
  end

  def post_process(doc), do: doc

  # ---------------------------------------------------------------------------
  # Frontmatter split / re-attach.
  #
  # Brain page bodies may begin with a `---` YAML frontmatter block. The editor
  # must never see frontmatter as content, so on load we split the raw block off
  # (preserving the user's exact YAML bytes — we do NOT re-serialize via
  # `Frontmatter.dump/1`) and convert only the remaining content; on save we
  # re-attach the same raw block verbatim in front of the serialized content.
  # ---------------------------------------------------------------------------

  @doc """
  Splits a leading `---` YAML frontmatter block off a page body.

  Returns `{raw_frontmatter_block, rest}`:

    * When the body begins with a frontmatter block, `raw_frontmatter_block` is
      the exact original bytes from the opening `---` through the closing `---`
      line and its trailing newline (no re-serialization — the user's YAML bytes
      are preserved). `rest` is everything after the closing delimiter's newline
      (so a blank line after the closing `---` becomes the start of `rest`).
    * When there is no leading frontmatter, returns `{"", body}`.

  A body counts as having frontmatter only when its very first line is exactly
  `---` (mirroring `Magus.Brain.Frontmatter`); GFM table separators like
  `| --- |` do not trigger it. A body that is only frontmatter with no trailing
  content yields `{block, ""}`.
  """
  @spec split_frontmatter(binary()) :: {binary(), binary()}
  def split_frontmatter(body) when is_binary(body) do
    if leading_delimiter?(body) do
      split_at_closing_delimiter(body)
    else
      {"", body}
    end
  end

  @doc """
  Re-attaches a raw frontmatter block (from `split_frontmatter/1`) in front of
  serialized content markdown. A no-op concatenation when the block is `""`.
  """
  @spec reattach_frontmatter(binary(), binary()) :: binary()
  def reattach_frontmatter(raw_frontmatter_block, content_markdown)
      when is_binary(raw_frontmatter_block) and is_binary(content_markdown) do
    raw_frontmatter_block <> content_markdown
  end

  @doc "Markdown body (with optional frontmatter) → ProseMirror JSON doc."
  def body_to_prosemirror(body) do
    {_fm, rest} = split_frontmatter(body || "")

    case Magus.Markdown.ProseMirror.from_markdown(rest, profile: __MODULE__) do
      {:ok, doc} -> doc
      _ -> Magus.Markdown.ProseMirror.default_doc()
    end
  end

  # The body has frontmatter only when the very first line is exactly `---`
  # (matching `Magus.Brain.Frontmatter.has_leading_delimiter?/1`). Bodies are
  # `\n`-delimited; CRLF tolerance is not required.
  defp leading_delimiter?(body) do
    body
    |> String.split("\n", parts: 2)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
    |> Kernel.==("---")
  end

  # Locate the closing `---` line by byte offset so the returned block preserves
  # the original bytes exactly. We re-split on `\n` (which is lossy w.r.t. the
  # final newline), so we recompute offsets from the original `body` rather than
  # rejoining the split pieces. The opening line is index 0; the first
  # subsequent line that is exactly `---` (trimmed) is the closing delimiter.
  defp split_at_closing_delimiter(body) do
    lines = String.split(body, "\n")

    case closing_delimiter_index(lines) do
      nil ->
        # Opening `---` with no closing delimiter: not a complete frontmatter
        # block. Treat the whole body as content (the load calculation / parser
        # handles malformed frontmatter separately).
        {"", body}

      idx ->
        # Byte length of lines 0..idx joined by `\n`, plus the trailing `\n` that
        # terminates the closing delimiter line. If the closing `---` is the very
        # last line with no trailing newline, there is no `\n` to include and
        # `rest` is empty.
        through_line = lines |> Enum.take(idx + 1) |> Enum.join("\n")
        through_bytes = byte_size(through_line)

        if byte_size(body) > through_bytes do
          # +1 for the `\n` after the closing `---` line.
          block = binary_part(body, 0, through_bytes + 1)
          rest = binary_part(body, through_bytes + 1, byte_size(body) - through_bytes - 1)
          {block, rest}
        else
          {body, ""}
        end
    end
  end

  # First line index (> 0) whose trimmed content is exactly `---`.
  defp closing_delimiter_index(lines) do
    lines
    |> Enum.drop(1)
    |> Enum.find_index(&(String.trim(&1) == "---"))
    |> case do
      nil -> nil
      i -> i + 1
    end
  end

  # ---------------------------------------------------------------------------
  # ProseMirror → markdown (block level). Ported byte-for-byte from
  # `Magus.Brain.BlockSerializer.block_to_markdown/1` (callout/source/file/
  # image/message) so the two writers agree exactly. Custom-node attrs are
  # camelCase here (`fileId`, `sourceType`, `messageId`, `previewText`); the
  # block serializer read them from `content` maps with snake/legacy keys.
  # Anything not handled here defers to the core's standard serialization.
  # ---------------------------------------------------------------------------

  @impl true
  def node_to_markdown(%{"type" => "calloutBlock", "attrs" => attrs}) do
    variant = attrs["variant"] || "info"
    text = attrs["text"] || ""

    md =
      if String.contains?(text, "\n") do
        indented = text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
        "```callout\nvariant: #{variant}\ntext: |\n#{indented}\n```"
      else
        ~s(```callout\nvariant: #{variant}\ntext: #{escape_yaml_scalar(text)}\n```)
      end

    {:ok, md}
  end

  def node_to_markdown(%{"type" => "sourceBlock", "attrs" => attrs}) do
    pairs =
      [
        {"url", attrs["url"]},
        {"title", attrs["title"]},
        {"source_type", attrs["sourceType"]},
        {"description", attrs["description"]},
        {"author", attrs["author"]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{escape_yaml_scalar(to_string(v))}" end)

    {:ok, "```source\n#{pairs}\n```"}
  end

  def node_to_markdown(%{"type" => "imageBlock", "attrs" => attrs}) do
    file_id = attrs["fileId"]
    caption = attrs["caption"] || ""

    if is_nil(file_id) or file_id == "" do
      :default
    else
      {:ok, "![#{caption}](magus://image/#{file_id})"}
    end
  end

  def node_to_markdown(%{"type" => "fileBlock", "attrs" => attrs}) do
    file_id = attrs["fileId"]
    caption = attrs["caption"] || ""

    if is_nil(file_id) or file_id == "" do
      :default
    else
      {:ok, "[#{@paperclip} #{caption}](magus://file/#{file_id})"}
    end
  end

  def node_to_markdown(%{"type" => "messageBlock"} = node), do: message_block_markdown(node)

  def node_to_markdown(_node), do: :default

  # ---------------------------------------------------------------------------
  # ProseMirror → markdown (inline level). `pageRef`/`tag` are inline atoms and
  # `messageBlock` may also sit inline inside a paragraph (post_process emits it
  # there), so it must serialize identically whether block- or inline-level.
  # ---------------------------------------------------------------------------

  @impl true
  def inline_node_to_markdown(%{"type" => "pageRef", "attrs" => attrs}) do
    {:ok, "[[#{attrs["title"]}]]"}
  end

  def inline_node_to_markdown(%{"type" => "tag", "attrs" => attrs}) do
    {:ok, "##{attrs["name"]}"}
  end

  def inline_node_to_markdown(%{"type" => "messageBlock"} = node),
    do: message_block_markdown(node)

  def inline_node_to_markdown(_node), do: :default

  # Shared by the block and inline message clauses. Ported from
  # `BlockSerializer.block_to_markdown/1` for `:message`.
  defp message_block_markdown(%{"attrs" => attrs}) do
    message_id = attrs["messageId"]
    preview = attrs["previewText"] || ""

    cond do
      is_nil(message_id) or message_id == "" -> :default
      preview == "" -> {:ok, "[[msg:#{message_id}]]"}
      true -> {:ok, "[[msg:#{message_id}|#{sanitize_msg_preview(preview)}]]"}
    end
  end

  # Wikilinks (and the `[[msg:...|preview]]` variant) cannot span newlines
  # because the lifting regex matches `[[([^\]\n]+)]]`. Collapse whitespace and
  # strip the pipe / square bracket chars that would break the syntax. Ported
  # from `BlockSerializer.sanitize_msg_preview/1`.
  defp sanitize_msg_preview(preview) do
    preview
    |> String.replace(["|", "[", "]"], " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Mirror the rules in `Magus.Brain.Frontmatter.dump_scalar/1` (and
  # `BlockSerializer.escape_yaml_scalar/1`) for inline YAML scalar values inside
  # fenced custom blocks.
  defp escape_yaml_scalar(s) when is_binary(s) do
    cond do
      String.contains?(s, ["\n", "\r"]) ->
        ~s("#{s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")}")

      String.contains?(s, [":", "#", "[", "]", "{", "}", ",", "\"", "\\"]) or
        String.starts_with?(s, " ") or String.ends_with?(s, " ") ->
        escaped = s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s("#{escaped}")

      true ->
        s
    end
  end

  defp escape_yaml_scalar(s), do: to_string(s)

  # ---------------------------------------------------------------------------
  # Block walk (mirrors transformBlock: flat_map so a node may expand/replace).
  # ---------------------------------------------------------------------------

  defp transform_blocks(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &transform_block/1)
  end

  # Fenced custom blocks (callout/source) arrive as `codeBlock` with the fence
  # language in attrs["language"] and the body in a single text node.
  defp transform_block(%{"type" => "codeBlock"} = node) do
    case fence_language(node) do
      "callout" ->
        fields = parse_fenced_yamlish(fence_body(node))

        [
          %{
            "type" => "calloutBlock",
            "attrs" => %{
              "variant" => field(fields, "variant", "note"),
              "text" => field(fields, "text", "")
            }
          }
        ]

      "source" ->
        fields = parse_fenced_yamlish(fence_body(node))

        [
          %{
            "type" => "sourceBlock",
            "attrs" => %{
              "url" => field(fields, "url", ""),
              "title" => field(fields, "title", ""),
              # Default matches the editor SourceBlock node ('web'), so
              # lifted legacy blocks serialize the same as freshly inserted
              # ones instead of omitting source_type.
              "sourceType" => field(fields, "source_type", "web"),
              "description" => field(fields, "description", ""),
              "author" => field(fields, "author", "")
            }
          }
        ]

      _ ->
        [node]
    end
  end

  # A paragraph holding exactly one magus:// image/link → atom block node.
  defp transform_block(%{"type" => "paragraph", "content" => [only]} = node) do
    case lift_single_child(only) do
      {:ok, lifted} -> [lifted]
      :no -> [descend(node)]
    end
  end

  defp transform_block(node), do: [descend(node)]

  # Descend into block containers (blockquote, lists, list/task items) and run
  # inline rewrites on text-bearing blocks (paragraph/heading/listItem/taskItem).
  defp descend(%{"content" => content} = node) when is_list(content) do
    content = transform_blocks(content)

    content =
      if node["type"] in ["paragraph", "heading", "listItem", "taskItem"] do
        rewrite_inlines(content)
      else
        content
      end

    %{node | "content" => content}
  end

  defp descend(node), do: node

  # ---------------------------------------------------------------------------
  # Single-child paragraph lifting (image → imageBlock, file link → fileBlock).
  # ---------------------------------------------------------------------------

  defp lift_single_child(%{"type" => "image", "attrs" => attrs}) do
    case Regex.run(@magus_image_re, attrs["src"] || "") do
      [_, id] ->
        {:ok,
         %{
           "type" => "imageBlock",
           "attrs" => %{"fileId" => id, "caption" => attrs["alt"] || ""}
         }}

      _ ->
        :no
    end
  end

  defp lift_single_child(%{"type" => "text", "text" => text, "marks" => marks})
       when is_list(marks) do
    with %{"attrs" => %{"href" => href}} <- Enum.find(marks, &(&1["type"] == "link")),
         [_, id] <- Regex.run(@magus_file_re, href || "") do
      {:ok,
       %{
         "type" => "fileBlock",
         "attrs" => %{"fileId" => id, "caption" => strip_paperclip(text)}
       }}
    else
      _ -> :no
    end
  end

  defp lift_single_child(_), do: :no

  defp strip_paperclip(text) do
    Regex.replace(~r/^\s*#{@paperclip}\s*/u, text, "")
  end

  # ---------------------------------------------------------------------------
  # Inline rewrites (mirror rewriteInlines/splitTextForAtoms).
  # Only operate on unmarked text nodes so existing marks round-trip intact.
  # ---------------------------------------------------------------------------

  defp rewrite_inlines(nodes) do
    Enum.flat_map(nodes, fn
      %{"type" => "text", "text" => text} = node when not is_map_key(node, "marks") ->
        split_text_for_atoms(text)

      %{"type" => "text", "marks" => []} = node ->
        split_text_for_atoms(node["text"] || "")

      other ->
        [other]
    end)
  end

  defp split_text_for_atoms(text) do
    wikilinks =
      Regex.scan(@wikilink_re, text, return: :index)
      |> Enum.map(fn [{start, len}, {body_start, body_len}] ->
        %{
          start: start,
          end: start + len,
          body: binary_part(text, body_start, body_len),
          kind: :wiki
        }
      end)

    tags =
      Regex.scan(@tag_re, text, return: :index)
      |> Enum.map(fn [_full, {_b_start, _b_len}, {name_start, name_len}] ->
        # The match starts at the boundary char; the `#` sits right after it.
        start = name_start - 1
        %{start: start, end: name_start + name_len, name: binary_part(text, name_start, name_len)}
      end)
      # Drop tag matches that overlap a wikilink (wikilinks take precedence).
      |> Enum.reject(fn t ->
        Enum.any?(wikilinks, fn w -> t.start >= w.start and t.start < w.end end)
      end)
      |> Enum.map(&Map.put(&1, :kind, :tag))

    atoms = Enum.sort_by(wikilinks ++ tags, & &1.start)

    if atoms == [] do
      [%{"type" => "text", "text" => text}]
    else
      build_atom_nodes(text, atoms)
    end
  end

  defp build_atom_nodes(text, atoms) do
    {nodes, cursor} =
      Enum.reduce(atoms, {[], 0}, fn atom, {acc, cursor} ->
        acc = maybe_text_segment(acc, text, cursor, atom.start)
        {[atom_node(atom) | acc], atom.end}
      end)

    nodes
    |> maybe_text_segment(text, cursor, byte_size(text))
    |> Enum.reverse()
    |> Enum.reject(fn node -> node["type"] == "text" and (node["text"] || "") == "" end)
  end

  defp maybe_text_segment(acc, _text, cursor, stop) when stop <= cursor, do: acc

  defp maybe_text_segment(acc, text, cursor, stop) do
    segment = binary_part(text, cursor, stop - cursor)
    [%{"type" => "text", "text" => segment} | acc]
  end

  defp atom_node(%{kind: :tag, name: name}) do
    %{"type" => "tag", "attrs" => %{"name" => name}}
  end

  defp atom_node(%{kind: :wiki, body: body}) do
    case Regex.run(@msg_ref_re, body) do
      [_, message_id] ->
        message_block(message_id, "")

      [_, message_id, preview] ->
        message_block(message_id, String.trim(preview))

      _ ->
        %{"type" => "pageRef", "attrs" => %{"title" => body}}
    end
  end

  defp message_block(message_id, preview_text) do
    %{
      "type" => "messageBlock",
      "attrs" => %{"messageId" => message_id, "previewText" => preview_text}
    }
  end

  # ---------------------------------------------------------------------------
  # Fence helpers.
  # ---------------------------------------------------------------------------

  defp fence_language(%{"attrs" => %{"language" => lang}}) when is_binary(lang), do: lang
  defp fence_language(_), do: ""

  defp fence_body(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} -> text
      _ -> ""
    end)
  end

  defp fence_body(_), do: ""

  defp field(fields, key, default) do
    case Map.get(fields, key) do
      nil -> default
      "" -> if default == "", do: "", else: default
      value -> value
    end
  end

  # Small YAML-ish parser mirroring parseFencedYamlish in brain_markdown.js.
  # Supports `key: value` and `key: |` block scalars (2-space-indented lines).
  defp parse_fenced_yamlish(raw) do
    raw
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> parse_lines(%{})
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/, line) do
      [_, key, "|"] ->
        {block, rest} = take_block_scalar(rest, [])
        parse_lines(rest, Map.put(acc, key, Enum.join(block, "\n")))

      [_, key, value] ->
        parse_lines(rest, Map.put(acc, key, unescape_yaml_scalar(value)))

      _ ->
        parse_lines(rest, acc)
    end
  end

  defp take_block_scalar([line | rest], acc) do
    if Regex.match?(~r/^\s{2,}/, line) do
      take_block_scalar(rest, [String.replace(line, ~r/^\s{2}/, "") | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp take_block_scalar([], acc), do: {Enum.reverse(acc), []}

  defp unescape_yaml_scalar(value) do
    trimmed = String.trim(value)

    if String.length(trimmed) >= 2 and String.starts_with?(trimmed, "\"") and
         String.ends_with?(trimmed, "\"") do
      trimmed
      |> String.slice(1..-2//1)
      |> String.replace("\\n", "\n")
      |> String.replace("\\\"", "\"")
      |> String.replace("\\\\", "\\")
    else
      trimmed
    end
  end
end
