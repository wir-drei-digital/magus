defmodule Magus.Brain.BlockSerializer do
  @moduledoc """
  Shared serializer that turns brain blocks into the JSON shape the
  TipTap editor JS hook consumes via the `data-blocks` attribute and
  the `brain:reload_blocks` push event.

  Three call sites use this:
  In the markdown-storage migration this serializer is still used by:

    - `Magus.Brain.Migrations.BackfillPageBody` — renders existing blocks
      to markdown for the body backfill (Phase B, still running until D).
    - `Mix.Tasks.Magus.Brain.ForceResync` — re-renders pages from blocks
      to catch any drift between the last backfill tick and Phase C
      cutover.
    - `Mix.Tasks.Magus.Brain.BackfillAudit` — re-renders sampled pages
      and byte-compares to body as a Phase D pre-flight integrity check.

  Phase D drops both the Block resource and this module entirely.

  Some call sites resolve `:file` block file metadata (name, mime, URL)
  into the block content; others don't. Pass `file_block_files` (a map of
  `file_id => file_summary | nil`) when enrichment is needed; pass `%{}`
  (or omit) when not.
  """

  alias Magus.Files

  @doc """
  Serializes a list of blocks. When `file_block_files` is provided,
  injects file metadata (with `url` resolved via `Files.Storage.get_url/1`)
  into `:file` block content under the `"file"` key.
  """
  @spec serialize_blocks([map()], %{optional(String.t()) => map() | nil} | nil) :: [map()]
  def serialize_blocks(blocks, file_block_files \\ %{})

  def serialize_blocks(blocks, file_block_files) when is_list(blocks) do
    Enum.map(blocks, &serialize_block(&1, file_block_files || %{}))
  end

  def serialize_blocks(_, _), do: []

  defp serialize_block(block, file_block_files) do
    base = %{
      id: block.id,
      type: to_string(block.type),
      content: block.content || %{},
      position: block.position,
      depth: block.depth,
      parent_block_id: block.parent_block_id,
      metadata: block.metadata || %{},
      contributor_type: block.contributor_type && to_string(block.contributor_type)
    }

    if block.type == :file do
      file_id = Map.get(block.content || %{}, "file_id")
      file = Map.get(file_block_files, file_id)
      put_in(base, [:content, "file"], file_summary_for_js(file))
    else
      base
    end
  end

  @doc """
  Builds the JS-shaped file summary used inside `:file` block content.
  Returns nil when the file is unavailable.
  """
  @spec file_summary_for_js(map() | nil) :: map() | nil
  def file_summary_for_js(nil), do: nil

  def file_summary_for_js(file) do
    %{
      id: Map.get(file, :id),
      name: file.name,
      mime_type: file.mime_type,
      type: to_string(file.type),
      file_size: file.file_size,
      file_path: file.file_path,
      status: to_string(file.status),
      url: file_url(file)
    }
  end

  @spec file_url(map()) :: String.t() | nil
  def file_url(%{file_path: nil}), do: nil

  def file_url(%{file_path: path}) when is_binary(path) do
    case Files.Storage.get_url(path) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  def file_url(_), do: nil

  @doc """
  Renders a list of blocks back to a markdown string. Used by the
  v2 HTTP API to round-trip page content (`GET /api/v2/pages/:id?format=markdown`)
  and by the Phase B backfill worker to populate `brain_pages.body`.

  Supported block types: paragraph, heading, code, quote, list_item,
  divider, callout, source, file, image, message, table. Unknown types
  fall back to their `"text"` content or are skipped if empty.

  Children of `:source` blocks are dropped from the output. In the
  legacy block model `SourceIngester` created child paragraphs holding
  the fetched URL content; in the markdown model that content moves to
  `Magus.Brain.Source.ingested_content` so the page body just carries
  the ` ```source ` fence with the URL/title/metadata.
  """
  @spec to_markdown([map()]) :: String.t()
  def to_markdown(blocks) when is_list(blocks) do
    source_block_ids = source_block_ids(blocks)

    blocks
    |> Enum.sort_by(& &1.position)
    |> Enum.reject(&source_child?(&1, source_block_ids))
    |> Enum.map(&block_to_markdown/1)
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n\n")
  end

  def to_markdown(_), do: ""

  defp source_block_ids(blocks) do
    blocks
    |> Enum.filter(&(&1.type == :source))
    |> MapSet.new(& &1.id)
  end

  defp source_child?(%{parent_block_id: pid}, source_ids) when not is_nil(pid),
    do: MapSet.member?(source_ids, pid)

  defp source_child?(_, _), do: false

  defp block_to_markdown(%{type: :paragraph, content: content}) do
    text_from(content)
  end

  defp block_to_markdown(%{type: :heading, content: content, metadata: meta}) do
    level = level_from(content, meta)
    prefix = String.duplicate("#", clamp_level(level))
    "#{prefix} #{text_from(content)}"
  end

  defp block_to_markdown(%{type: :code, content: content, metadata: meta}) do
    language = language_from(meta)
    "```#{language}\n#{text_from(content)}\n```"
  end

  defp block_to_markdown(%{type: :quote, content: content}) do
    content
    |> text_from()
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp block_to_markdown(%{type: :list_item, content: content, metadata: meta}) do
    depth = depth_from(meta)
    indent = String.duplicate("  ", depth)
    text = text_from(content)

    case task_checkbox(content, meta) do
      :checked -> "#{indent}- [x] #{text}"
      :unchecked -> "#{indent}- [ ] #{text}"
      :none -> "#{indent}- #{text}"
    end
  end

  defp block_to_markdown(%{type: :divider}), do: "---"

  defp block_to_markdown(%{type: :callout, content: content}) do
    variant = Map.get(content || %{}, "variant") || "info"
    text = text_from(content)

    if String.contains?(text, "\n") do
      indented = text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
      "```callout\nvariant: #{variant}\ntext: |\n#{indented}\n```"
    else
      ~s(```callout\nvariant: #{variant}\ntext: #{escape_yaml_scalar(text)}\n```)
    end
  end

  defp block_to_markdown(%{type: :source, content: content}) do
    c = content || %{}

    pairs =
      [
        {"url", c["url"]},
        {"title", c["title"] || c["text"]},
        {"source_type", c["source_type"]},
        {"description", c["description"]},
        {"author", c["author"]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{escape_yaml_scalar(to_string(v))}" end)

    "```source\n#{pairs}\n```"
  end

  defp block_to_markdown(%{type: :file, content: content}) do
    c = content || %{}
    file_id = c["file_id"]
    caption = c["caption"] || c["text"] || ""

    cond do
      is_nil(file_id) or file_id == "" -> nil
      true -> "[📎 #{caption}](magus://file/#{file_id})"
    end
  end

  defp block_to_markdown(%{type: :image, content: content}) do
    c = content || %{}
    file_id = c["file_id"]
    caption = c["caption"] || c["text"] || ""

    cond do
      is_nil(file_id) or file_id == "" -> nil
      true -> "![#{caption}](magus://image/#{file_id})"
    end
  end

  defp block_to_markdown(%{type: :message, content: content}) do
    c = content || %{}
    message_id = c["message_id"]
    preview = c["preview_text"] || c["text"] || ""

    cond do
      is_nil(message_id) or message_id == "" ->
        nil

      preview == "" ->
        "[[msg:#{message_id}]]"

      true ->
        "[[msg:#{message_id}|#{sanitize_msg_preview(preview)}]]"
    end
  end

  defp block_to_markdown(%{type: :table, content: content}) do
    case Map.get(content || %{}, "table") do
      %{"type" => "table"} = table_node ->
        doc = %{"type" => "doc", "content" => [table_node]}
        Magus.Drafts.ProseMirrorConverter.to_markdown(doc) |> String.trim()

      _ ->
        nil
    end
  end

  defp block_to_markdown(%{content: content}) do
    case text_from(content) do
      "" -> nil
      text -> text
    end
  end

  defp block_to_markdown(_), do: nil

  # Wikilinks (and the `[[msg:...|preview]]` variant) cannot span newlines
  # because the JS markdown-to-prosemirror transform matches them with a
  # `[[([^\]\n]+)]]` regex. Collapse whitespace and strip the pipe / square
  # bracket chars that would break the syntax.
  defp sanitize_msg_preview(preview) do
    preview
    |> String.replace(["|", "[", "]"], " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # Mirror the rules in Magus.Brain.Frontmatter.dump_scalar/1 but for inline
  # YAML scalar values inside fenced custom blocks.
  defp escape_yaml_scalar(s) when is_binary(s) do
    cond do
      String.contains?(s, ["\n", "\r"]) ->
        # Multi-line scalars are emitted by the callout branch using block
        # scalars (`|`), not this helper. Anything reaching this branch with
        # a newline is unexpected; preserve safely by quoting and escaping.
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

  defp text_from(%{} = content), do: Map.get(content, "text") || ""
  defp text_from(_), do: ""

  defp level_from(content, meta) do
    cond do
      is_map(content) and is_integer(Map.get(content, "level")) -> Map.get(content, "level")
      is_map(meta) and is_integer(Map.get(meta, :level)) -> Map.get(meta, :level)
      is_map(meta) and is_integer(Map.get(meta, "level")) -> Map.get(meta, "level")
      true -> 1
    end
  end

  defp clamp_level(level) when is_integer(level) and level > 0, do: min(level, 6)
  defp clamp_level(_), do: 1

  defp language_from(meta) when is_map(meta) do
    Map.get(meta, :language) || Map.get(meta, "language") || ""
  end

  defp language_from(_), do: ""

  defp depth_from(meta) when is_map(meta) do
    case Map.get(meta, :depth) || Map.get(meta, "depth") do
      d when is_integer(d) and d > 0 -> d
      _ -> 0
    end
  end

  defp depth_from(_), do: 0

  # Returns :checked / :unchecked when the list item is a task item
  # (the `checked` key is present with a boolean value), or :none for
  # a regular bullet.
  defp task_checkbox(content, meta) do
    content_val = Map.get(content || %{}, "checked")
    meta_val = Map.get(meta || %{}, :checked) || Map.get(meta || %{}, "checked")

    cond do
      content_val == true or meta_val == true -> :checked
      content_val == false or meta_val == false -> :unchecked
      true -> :none
    end
  end
end
