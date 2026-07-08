defmodule Magus.Agents.Context.BrainContext do
  @moduledoc """
  Builds brain context for AI agents.

  When a brain page is open in the pane, provides the agent with the brain's
  structure and a preview of the current page's markdown body. Phase C5 of the
  markdown-storage migration: this module reads `page.body` directly instead
  of iterating over blocks. The block resource is being retired in Phase D.

  Follows the same pattern as `DraftContext` for context injection into the
  system prompt.
  """

  alias Magus.Brain
  alias Magus.Brain.BodyParser
  alias Magus.Brain.Frontmatter
  alias Magus.Brain.Guide
  alias Magus.Brain.Hierarchy

  @body_preview_limit 500

  # Page tree is rendered as a "neighborhood" around the active page:
  # full ancestor chain + siblings + direct children. These caps keep the
  # context cheap on large brains; the footer surfaces the total count
  # whenever the neighborhood is a subset of the brain.
  @max_siblings 10
  @max_children 10

  # Companion context inlines the WHOLE page tree (not just a neighborhood)
  # so the agent never has to call list_pages for its own page. Capped to
  # keep token cost bounded on very large brains.
  @max_tree_pages 400

  @spec build(String.t() | nil, String.t() | nil, keyword()) :: String.t() | nil
  def build(brain_id, page_id, opts \\ [])
  def build(nil, _page_id, _opts), do: nil
  def build(_brain_id, nil, _opts), do: nil

  def build(brain_id, page_id, opts) do
    # `workspace_id` is a routing concern for the available-brains list, not a
    # valid option for Ash.get/list_pages — extract it out before querying.
    {workspace_id, ash_opts} = Keyword.pop(opts, :workspace_id)
    actor = Keyword.get(ash_opts, :actor)

    with {:ok, brain} <- Ash.get(Brain.BrainResource, brain_id, ash_opts),
         {:ok, page} <- Ash.get(Brain.Page, page_id, ash_opts),
         {:ok, pages} <- Brain.list_pages(brain_id, ash_opts) do
      compose(brain, page, pages, actor, workspace_id)
    else
      _ -> nil
    end
  end

  @doc """
  Guide block for TOOL RESULTS: loads only the metadata the ancestor walk
  needs (no bodies) and renders `guide_section/4`.

  Just-in-time steering for pure-tool flows: when no pane or companion
  injected the Guide up front, entering a location via `read_page` or
  writing via `write_page` surfaces that location's rules with the result,
  CLAUDE.md-style.
  """
  @spec tool_guide_section(Ash.Resource.record() | nil, Ash.Resource.record() | nil, term()) ::
          String.t() | nil
  def tool_guide_section(brain, page, actor) when is_map(brain) and is_map(page) do
    require Ash.Query

    pages =
      Brain.Page
      |> Ash.Query.filter(brain_id == ^brain.id and is_nil(deleted_at) and kind != :template)
      |> Ash.Query.select([:id, :title, :parent_page_id, :position, :frontmatter, :kind])
      |> Ash.read(actor: actor)
      |> case do
        {:ok, pages} -> pages
        _ -> []
      end

    guide_section(brain, page, pages, actor)
  end

  def tool_guide_section(_brain, _page, _actor), do: nil

  @doc """
  Formatted "### Available brains" section listing the actor's brains
  (title + id), or `nil` when the actor has none. `workspace_id` scopes the
  lookup the same way the agent brain tools do (nil = personal brains).
  """
  @spec available_brains_section(Ash.Resource.record() | nil, String.t() | nil) ::
          String.t() | nil
  def available_brains_section(nil, _workspace_id), do: nil

  def available_brains_section(user, workspace_id) do
    case Magus.Brain.Resolver.list_brain_summaries(user, workspace_id: workspace_id) do
      {:ok, [_ | _] = brains} ->
        lines =
          Enum.map_join(brains, "\n", fn {id, title} ->
            "- #{title || "Untitled"} (brain_id: #{id})"
          end)

        "### Available brains\n\n" <> lines

      _ ->
        nil
    end
  end

  @doc """
  Renders the FULL page tree (one line per node, id per node, indented by
  depth), marking `active_page_id` with a `[THIS PAGE]` marker. Capped at
  `@max_tree_pages`; a footer note is appended when the tree is truncated.
  """
  @spec full_tree([map()], String.t() | nil) :: String.t()
  def full_tree(pages, active_page_id) do
    by_parent = Enum.group_by(pages, & &1.parent_page_id)
    roots = by_parent |> Map.get(nil, []) |> Enum.sort_by(& &1.position)
    lines = render_tree(roots, by_parent, 0, active_page_id)
    capped = Enum.take(lines, @max_tree_pages)
    base = Enum.join(capped, "\n")

    if length(lines) > @max_tree_pages do
      base <>
        "\n- ... +#{length(lines) - @max_tree_pages} more pages (call read_brain.list_pages for the rest)"
    else
      base
    end
  end

  defp render_tree(nodes, by_parent, depth, active_id) do
    Enum.flat_map(nodes, fn page ->
      marker = if page.id == active_id, do: " [THIS PAGE]", else: ""

      line =
        "#{String.duplicate("  ", depth)}- #{page.title || "Untitled"}#{marker} (id: #{page.id})"

      children = by_parent |> Map.get(page.id, []) |> Enum.sort_by(& &1.position)
      [line | render_tree(children, by_parent, depth + 1, active_id)]
    end)
  end

  defp compose(brain, page, pages, actor, workspace_id) do
    body = page.body || ""
    frontmatter = normalize_frontmatter(page.frontmatter)

    {fm_from_body, body_without_frontmatter} =
      case Frontmatter.parse(body) do
        {fm, rest} when is_map(fm) -> {fm, rest}
        _ -> {%{}, body}
      end

    # Prefer the cached frontmatter on the page (populated by the Phase C
    # update_body pipeline). Fall back to whatever we just parsed out of the
    # body so that pages backfilled before the cache was populated still
    # surface their tags/icon.
    effective_frontmatter =
      if map_size(frontmatter) > 0, do: frontmatter, else: fm_from_body

    page_list = format_page_neighborhood(pages, page)
    breadcrumb = Hierarchy.build_breadcrumb(page, pages)

    stats_line = build_stats_line(pages, body, effective_frontmatter)
    frontmatter_line = build_frontmatter_line(effective_frontmatter)
    guide_section = guide_section(brain, page, pages, actor)
    body_preview = build_body_preview(body_without_frontmatter)
    sources_section = build_sources_section(body)
    brains_section = wrap_brains_section(available_brains_section(actor, workspace_id))

    sections =
      [
        "## Knowledge Brain",
        "",
        "Brain: **#{brain.title}**#{describe_brain(brain)}",
        stats_line,
        "Current Page: **#{breadcrumb}**",
        frontmatter_line,
        "Pages near current:",
        page_list,
        "",
        guide_section,
        "### Current Page Body",
        "",
        body_preview,
        sources_section,
        brains_section
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    String.trim(sections)
  end

  defp wrap_brains_section(nil), do: nil
  defp wrap_brains_section(section), do: "\n" <> section

  defp describe_brain(%{description: nil}), do: ""
  defp describe_brain(%{description: ""}), do: ""
  defp describe_brain(%{description: desc}) when is_binary(desc), do: " - #{desc}"
  defp describe_brain(_), do: ""

  defp build_stats_line(pages, body, frontmatter) do
    page_count = length(pages)
    line_count = body |> String.split("\n") |> length()
    source_count = body |> BodyParser.source_urls() |> length()
    wikilink_count = body |> BodyParser.wikilinks() |> length()
    tag_count = count_tags(body, frontmatter)

    "Stats: #{page_count} pages, #{line_count} lines, #{source_count} sources, " <>
      "#{wikilink_count} wikilinks, #{tag_count} tags"
  end

  defp count_tags(body, frontmatter) do
    inline = BodyParser.inline_tags(body)
    fm_tags = Map.get(frontmatter, "tags", [])
    (inline ++ fm_tags) |> Enum.uniq() |> length()
  end

  defp build_frontmatter_line(frontmatter) when map_size(frontmatter) == 0, do: nil

  defp build_frontmatter_line(frontmatter) do
    parts =
      []
      |> append_part(format_icon(frontmatter))
      |> append_part(format_type(frontmatter))
      |> append_part(format_tags(frontmatter))

    case parts do
      [] -> nil
      _ -> "Frontmatter: " <> Enum.join(parts, " | ")
    end
  end

  defp append_part(parts, nil), do: parts
  defp append_part(parts, value), do: parts ++ [value]

  defp format_icon(%{"icon" => icon}) when is_binary(icon) and icon != "", do: "icon #{icon}"
  defp format_icon(_), do: nil

  defp format_type(%{"type" => type}) when is_binary(type) and type != "", do: "type: #{type}"
  defp format_type(_), do: nil

  defp format_tags(%{"tags" => tags}) when is_list(tags) and tags != [] do
    "tags: " <> Enum.map_join(tags, ", ", &"##{&1}")
  end

  defp format_tags(_), do: nil

  @doc """
  Renders the `### Brain Guide` block: constitution, inherited section
  guides for the active page's location, and the brain's types index.
  Returns nil when `Guide` has nothing to show (see `Guide.empty?/1`).

  Public because `CompanionPreamble` embeds the same block in brain-page
  companion chats (the always-on injection path), so both render identically.
  """
  @spec guide_section(
          Ash.Resource.record(),
          Ash.Resource.record(),
          [Ash.Resource.record()],
          term()
        ) :: String.t() | nil
  def guide_section(brain, page, pages, actor) do
    guide = Guide.for_page(brain, page, pages, actor)

    if Guide.empty?(guide) do
      nil
    else
      parts =
        [
          render_constitution(guide.constitution),
          render_section_guides(guide.section_guides),
          render_types(guide.types)
        ]
        |> Enum.reject(&is_nil/1)

      "### Brain Guide\n\n" <> Enum.join(parts, "\n\n") <> "\n"
    end
  end

  defp render_constitution(nil), do: nil
  defp render_constitution(text), do: "**Constitution:**\n\n#{text}"

  defp render_section_guides([]), do: nil

  defp render_section_guides(section_guides) do
    lines =
      Enum.map_join(section_guides, "\n\n", fn %{title: title, instructions: instructions} ->
        "**#{title}:** #{instructions}"
      end)

    "**Section guides** (root to current; nearest applies most):\n\n#{lines}"
  end

  defp render_types([]), do: nil

  defp render_types(types) do
    lines =
      Enum.map_join(types, "\n", fn %{title: title, description: description} ->
        if description == "" do
          "- #{title}"
        else
          "- #{title}: #{description}"
        end
      end)

    "**Types:**\n\n#{lines}"
  end

  defp build_body_preview(""), do: "_(empty page)_"
  defp build_body_preview(nil), do: "_(empty page)_"

  defp build_body_preview(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        "_(empty page)_"

      String.length(trimmed) <= @body_preview_limit ->
        trimmed

      true ->
        String.slice(trimmed, 0, @body_preview_limit) <> "…"
    end
  end

  defp build_sources_section(body) do
    case BodyParser.source_urls(body) do
      [] ->
        nil

      urls ->
        listed = Enum.map_join(urls, "\n", &"- #{&1}")
        "\n### Sources referenced\n\n" <> listed
    end
  end

  defp normalize_frontmatter(fm) when is_map(fm), do: fm
  defp normalize_frontmatter(_), do: %{}

  # Renders a localized view of the page tree: full ancestor chain + the
  # active page's siblings + the active page's direct children. Siblings
  # and children are capped at @max_siblings / @max_children with a
  # "... +N more" line. If the rendered set is smaller than the whole
  # brain, a footer surfaces the total count so the agent can call
  # `read_brain.list_pages` to see the rest.
  defp format_page_neighborhood(pages, active_page) do
    pages_by_id = Map.new(pages, &{&1.id, &1})
    active = Map.get(pages_by_id, active_page.id, active_page)

    ancestors = Hierarchy.ancestor_pages(active, pages)
    ancestor_depth = length(ancestors)

    siblings =
      pages
      |> Enum.filter(&(&1.parent_page_id == active.parent_page_id))
      |> Enum.sort_by(& &1.position)

    children =
      pages
      |> Enum.filter(&(&1.parent_page_id == active.id))
      |> Enum.sort_by(& &1.position)

    ancestor_lines =
      ancestors
      |> Enum.with_index()
      |> Enum.map(fn {p, depth} -> render_node(p, depth, "") end)

    {sibling_section, hidden_siblings, visible_sibling_ids} =
      render_siblings(siblings, active, ancestor_depth, children)

    sibling_truncation_line =
      if hidden_siblings > 0,
        do: [render_truncation(ancestor_depth, hidden_siblings, "sibling")],
        else: []

    lines = ancestor_lines ++ sibling_section ++ sibling_truncation_line

    # Hidden count = total pages NOT rendered. Rendered set = ancestors +
    # visible siblings (including active) + (capped) children.
    rendered_ids =
      MapSet.new(Enum.map(ancestors, & &1.id))
      |> MapSet.union(visible_sibling_ids)
      |> MapSet.union(MapSet.new(Enum.take(children, @max_children) |> Enum.map(& &1.id)))

    hidden_total = length(pages) - MapSet.size(rendered_ids)

    footer =
      if hidden_total > 0,
        do: [
          "",
          "(neighborhood view; brain has #{length(pages)} pages total — call `read_brain.list_pages` for the rest)"
        ],
        else: []

    Enum.join(lines ++ footer, "\n")
  end

  defp render_siblings(siblings, active, depth, children) do
    siblings_to_show = Enum.take(siblings, @max_siblings)

    {must_include_active?, siblings_to_show} =
      if Enum.any?(siblings_to_show, &(&1.id == active.id)) do
        {false, siblings_to_show}
      else
        # Active page didn't fit in the truncated window. Replace the last
        # sibling slot with active so the agent always sees its location.
        {true, Enum.take(siblings, @max_siblings - 1) ++ [active]}
      end

    hidden_siblings = max(0, length(siblings) - length(siblings_to_show))

    visible_ids =
      siblings_to_show
      |> Enum.map(& &1.id)
      |> MapSet.new()

    lines =
      Enum.flat_map(siblings_to_show, fn p ->
        if p.id == active.id do
          [render_node(p, depth, " [ACTIVE]") | render_children_block(children, depth + 1)]
        else
          [render_node(p, depth, "")]
        end
      end)

    # Suppress the "and active was forced in" duplication if active was already
    # in the truncated window; otherwise the truncation count needs to reflect
    # that we displaced one entry.
    _ = must_include_active?

    {lines, hidden_siblings, visible_ids}
  end

  defp render_children_block(children, depth) do
    to_show = Enum.take(children, @max_children)
    hidden = max(0, length(children) - length(to_show))

    base = Enum.map(to_show, &render_node(&1, depth, ""))

    if hidden > 0 do
      base ++ [render_truncation(depth, hidden, "child")]
    else
      base
    end
  end

  defp render_node(page, depth, marker) do
    indent = String.duplicate("  ", depth)
    "#{indent}- #{page.title || "Untitled"}#{marker} (id: #{page.id})"
  end

  defp render_truncation(depth, count, kind) do
    indent = String.duplicate("  ", depth)
    plural = if count == 1, do: " page", else: " pages"
    "#{indent}- ... +#{count} more #{kind}#{plural}"
  end
end
