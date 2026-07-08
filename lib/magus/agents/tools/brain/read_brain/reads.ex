defmodule Magus.Agents.Tools.Brain.ReadBrain.Reads do
  @moduledoc """
  `ReadBrain` action handlers for listing, finding, and reading brain
  content: `list_brains`, `list_pages`, `find_page`, `get_backlinks`,
  `list_tags`, `read_page`, `peek_page`, and `read_source`.

  Extracted verbatim from `Magus.Agents.Tools.Brain.ReadBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged.
  """

  require Ash.Query

  alias Magus.Brain
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_int_param: 3, tool_error: 3]

  import Magus.Agents.Tools.Brain.ReadBrain.Support,
    only: [
      build_current: 2,
      load_brain: 2,
      load_brain_by_id: 2,
      build_breadcrumb: 2,
      blank?: 1,
      resolve_page_for_read: 4,
      resolve_brain_pairs: 3,
      slice_body: 4,
      line_count: 1
    ]

  # ---------------------------------------------------------------------------
  # list_brains
  # ---------------------------------------------------------------------------

  def handle_list_brains(_params, ctx, context) do
    workspace_id = Map.get(context, :workspace_id)

    brains_result =
      case workspace_id do
        nil -> Brain.list_brains(actor: ctx.user)
        ws_id -> Brain.list_brains_for_workspace(ws_id, actor: ctx.user)
      end

    case brains_result do
      {:ok, brains} ->
        scope = if workspace_id, do: "workspace", else: "personal"

        formatted =
          Enum.map(brains, fn b ->
            base = %{
              brain_id: b.id,
              title: b.title,
              description: b.description,
              icon: b.icon,
              workspace_id: b.workspace_id
            }

            if workspace_id do
              Map.put(base, :is_shared_to_workspace, b.is_shared_to_workspace)
            else
              base
            end
          end)

        hint =
          if formatted == [] do
            "No brains found in this #{scope} scope. Use edit_brain (create_brain action) to create one."
          else
            "#{length(formatted)} brain(s) in this #{scope} scope. Hint: pass brain_id to other actions to scope them to a specific brain."
          end

        {:ok,
         %{
           action: "list_brains",
           scope: scope,
           count: length(formatted),
           brains: formatted,
           hint: hint
         }}

      {:error, err} ->
        {:ok,
         %{
           error: tool_error("list brains", err, "Check that the actor has access to any brains.")
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # list_pages
  # ---------------------------------------------------------------------------

  def handle_list_pages(params, ctx, context) do
    parent_page_id = get_param(params, :parent_page_id)
    root_only = get_param(params, :root_only)
    tags = normalize_tag_filter(get_param(params, :tag))

    pages_result =
      cond do
        parent_page_id ->
          Brain.list_children_pages(parent_page_id, actor: ctx.user)

        root_only == true ->
          case BrainResolver.resolve_brain_id(context, params) do
            {:ok, brain_id} -> Brain.list_root_pages(brain_id, actor: ctx.user)
            {:error, msg} -> {:error, msg}
          end

        true ->
          case BrainResolver.resolve_brain_id(context, params) do
            {:ok, brain_id} -> Brain.list_pages(brain_id, actor: ctx.user)
            {:error, msg} -> {:error, msg}
          end
      end

    case pages_result do
      {:ok, pages} ->
        filtered = apply_tag_filter(pages, tags, ctx.user)
        ordered = sort_pages_in_tree_order(filtered)
        children_index = build_children_index(filtered)

        formatted =
          Enum.map(ordered, fn p ->
            %{
              page_id: p.id,
              title: p.title,
              slug: p.slug,
              icon: p.icon,
              parent_page_id: p.parent_page_id,
              depth: p.depth,
              position: p.position,
              has_children?: Map.has_key?(children_index, p.id)
            }
          end)

        count = length(formatted)

        {:ok,
         %{
           action: "list_pages",
           count: count,
           pages: formatted,
           tree: render_tree_text(ordered),
           hint:
             "#{count} pages. Hint: use read_brain.read_page to view content, or find_page to search by topic."
         }}

      {:error, msg} when is_binary(msg) ->
        {:ok, %{error: msg}}

      {:error, err} ->
        {:ok,
         %{
           error:
             tool_error(
               "list pages",
               err,
               "Verify brain_id with read_brain list_brains."
             )
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # find_page
  # ---------------------------------------------------------------------------

  def handle_find_page(params, ctx, context) do
    query = get_param(params, :query)

    if is_nil(query) or query == "" do
      {:ok, %{error: "Missing required parameter: query"}}
    else
      limit = get_int_param(params, :limit, 20)
      boost_tags = normalize_tag_list(get_param(params, :tags))
      brain_pairs = resolve_brain_pairs(params, context, ctx)

      cond do
        brain_pairs == [] ->
          {:ok,
           %{
             action: "find_page",
             count: 0,
             pages: [],
             hint:
               "No accessible brains. Hint: use edit_brain create_brain to create one, then write_page to add content."
           }}

        true ->
          ranked =
            brain_pairs
            |> Enum.flat_map(fn {brain_id, brain_title} ->
              find_in_brain(query, brain_id, brain_title, ctx.user)
            end)
            |> apply_tag_boost(boost_tags, ctx.user)
            |> Enum.sort_by(& &1.score, :desc)
            |> Enum.take(limit)

          hint =
            if ranked == [] do
              "No matching pages found across #{length(brain_pairs)} brain(s). Hint: use edit_brain.write_page with a new title to create a page."
            else
              "Hint: use read_brain.read_page to view a match, edit_brain.write_page :append to add to one, or edit_brain.write_page :create for a fresh page."
            end

          {:ok,
           %{
             action: "find_page",
             count: length(ranked),
             pages: ranked,
             hint: hint
           }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # get_backlinks
  # ---------------------------------------------------------------------------

  def handle_get_backlinks(params, ctx) do
    page_id = get_param(params, :page_id)

    cond do
      is_nil(page_id) ->
        {:ok, %{error: "Missing required parameter: page_id for get_backlinks"}}

      true ->
        case Brain.list_backlinks(page_id, load: [:source_page], actor: ctx.user) do
          {:ok, links} ->
            formatted =
              links
              |> Enum.map(fn link ->
                source_page = link.source_page

                %{
                  source_page_id: link.source_page_id,
                  source_page_title: source_page && (source_page.title || "Untitled"),
                  brain_id: source_page && source_page.brain_id,
                  target_title_at_link_time: link.target_title_at_link_time
                }
              end)

            count = length(formatted)

            hint =
              if count == 0 do
                "No pages link to this one. Hint: add `[[Page Name]]` in another page's body to create a backlink."
              else
                "#{count} backlink(s). Hint: target_title_at_link_time reveals rename drift between the original wikilink text and the current page title."
              end

            {:ok,
             %{
               action: "get_backlinks",
               page_id: page_id,
               count: count,
               backlinks: formatted,
               hint: hint
             }}

          {:error, err} ->
            {:ok,
             %{
               error:
                 tool_error(
                   "get backlinks",
                   err,
                   "Verify page_id with read_brain list_pages."
                 )
             }}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # list_tags
  # ---------------------------------------------------------------------------

  def handle_list_tags(params, ctx, context) do
    explicit_brain_id = get_param(params, :brain_id)
    brain_pairs = resolve_brain_pairs(params, context, ctx)

    cond do
      brain_pairs == [] ->
        {:ok,
         %{
           action: "list_tags",
           count: 0,
           tags: [],
           hint: "No accessible brains."
         }}

      true ->
        brain_title_map = Map.new(brain_pairs)
        brain_ids = Enum.map(brain_pairs, fn {bid, _} -> bid end)

        tags = aggregate_tags(brain_ids, brain_title_map, ctx.user)

        scope_hint =
          cond do
            explicit_brain_id -> "scoped to one brain"
            length(brain_pairs) == 1 -> "scoped to your one brain"
            true -> "across #{length(brain_pairs)} brain(s)"
          end

        {:ok,
         %{
           action: "list_tags",
           count: length(tags),
           tags: tags,
           hint:
             "#{length(tags)} tag(s) #{scope_hint}. Hint: pass `tag` to list_pages to filter by one (or `tags` to find_page to boost matches)."
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # read_page
  # ---------------------------------------------------------------------------

  def handle_read_page(params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
      start_line = get_param(params, :start_line)
      end_line = get_param(params, :end_line)
      body = page.body || ""
      line_count = line_count(body)
      breadcrumb = build_breadcrumb(page, ctx)
      brain = load_brain(page, ctx)

      sliced =
        case slice_body(body, start_line, end_line, line_count) do
          {:ok, content} -> content
          {:error, msg} -> msg
        end

      payload = %{
        action: "read_page",
        page_id: page.id,
        page_title: page.title,
        body: sliced,
        line_count: line_count,
        breadcrumb: breadcrumb,
        frontmatter: page.frontmatter || %{},
        current: build_current(brain, page)
      }

      payload =
        if blank?(body) and is_nil(start_line) do
          Map.put(payload, :hint, "Page is empty. Use write_page to add content.")
        else
          payload
        end

      {:ok, payload}
    else
      {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
      {:error, err} -> {:ok, %{error: tool_error("read page", err, nil)}}
    end
  end

  # ---------------------------------------------------------------------------
  # peek_page
  # ---------------------------------------------------------------------------

  def handle_peek_page(params, ctx, context) do
    with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
         {:ok, page} <- resolve_page_for_read(context, params, brain_id, ctx) do
      body = page.body || ""
      brain = load_brain(page, ctx)

      {:ok,
       %{
         action: "peek_page",
         page_id: page.id,
         page_title: page.title,
         first_200_chars: String.slice(body, 0, 200),
         line_count: line_count(body),
         last_modified_at: page.updated_at,
         current: build_current(brain, page)
       }}
    else
      {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
      {:error, err} -> {:ok, %{error: tool_error("peek page", err, nil)}}
    end
  end

  # ---------------------------------------------------------------------------
  # read_source
  # ---------------------------------------------------------------------------

  def handle_read_source(params, ctx, context) do
    source_id = get_param(params, :source_id)
    url = get_param(params, :url)

    cond do
      not is_nil(source_id) ->
        case Brain.get_source(source_id, actor: ctx.user) do
          {:ok, source} -> {:ok, format_source(source, ctx)}
          {:error, err} -> {:ok, %{error: tool_error("read source", err, nil)}}
        end

      not is_nil(url) ->
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            case Brain.find_source_by_url(brain_id, url, actor: ctx.user) do
              {:ok, source} ->
                {:ok, format_source(source, ctx)}

              {:error, err} ->
                {:ok,
                 %{
                   error:
                     tool_error(
                       "read source by url",
                       err,
                       "Confirm the URL has been ingested into this brain."
                     )
                 }}
            end

          {:error, msg} ->
            {:ok, %{error: msg}}
        end

      true ->
        {:ok, %{error: "Provide either source_id or url (with brain_id when ambiguous)."}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — pages
  # ---------------------------------------------------------------------------

  defp sort_pages_in_tree_order([]), do: []

  defp sort_pages_in_tree_order(pages) do
    by_parent = Enum.group_by(pages, & &1.parent_page_id)
    page_ids = MapSet.new(pages, & &1.id)

    {known_parent, orphan} =
      pages
      |> Enum.split_with(fn p ->
        is_nil(p.parent_page_id) or MapSet.member?(page_ids, p.parent_page_id)
      end)

    roots =
      known_parent
      |> Enum.filter(&is_nil(&1.parent_page_id))
      |> Enum.sort_by(& &1.position)

    orphan_sorted = Enum.sort_by(orphan, & &1.position)

    orphan_sorted ++ Enum.flat_map(roots, &walk_subtree(&1, by_parent))
  end

  defp walk_subtree(page, by_parent) do
    children =
      by_parent
      |> Map.get(page.id, [])
      |> Enum.sort_by(& &1.position)

    [page | Enum.flat_map(children, &walk_subtree(&1, by_parent))]
  end

  defp build_children_index(pages) do
    pages
    |> Enum.reject(&is_nil(&1.parent_page_id))
    |> Enum.group_by(& &1.parent_page_id)
  end

  defp render_tree_text([]), do: ""

  defp render_tree_text(pages) do
    min_depth = pages |> Enum.map(& &1.depth) |> Enum.min()

    pages
    |> Enum.map_join("\n", fn p ->
      indent = String.duplicate("  ", max(p.depth - min_depth, 0))
      title = p.title || "Untitled"
      "#{indent}- #{title}"
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers — tag filtering / boosting
  # ---------------------------------------------------------------------------

  defp normalize_tag_filter(nil), do: nil
  defp normalize_tag_filter([]), do: nil

  defp normalize_tag_filter(tags) when is_list(tags) do
    tags
    |> Enum.map(&Magus.Brain.Frontmatter.normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp normalize_tag_filter(tag) when is_binary(tag) do
    normalize_tag_filter([tag])
  end

  defp normalize_tag_list(nil), do: []

  defp normalize_tag_list(tags) when is_list(tags) do
    tags
    |> Enum.map(&Magus.Brain.Frontmatter.normalize_tag/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_tag_list(tag) when is_binary(tag), do: normalize_tag_list([tag])

  defp apply_tag_filter(pages, nil, _user), do: pages

  defp apply_tag_filter([], _tags, _user), do: []

  defp apply_tag_filter(pages, tags, user) do
    page_ids = Enum.map(pages, & &1.id)

    tag_rows =
      Magus.Brain.PageTag
      |> Ash.Query.filter(page_id in ^page_ids and tag in ^tags)
      |> Ash.read!(actor: user)

    matching_by_page =
      tag_rows
      |> Enum.group_by(& &1.page_id, & &1.tag)
      |> Map.new(fn {pid, tag_list} -> {pid, Enum.uniq(tag_list)} end)

    Enum.filter(pages, fn page ->
      matched = Map.get(matching_by_page, page.id, [])
      Enum.all?(tags, &(&1 in matched))
    end)
  end

  defp apply_tag_boost(pages, [], _user), do: pages

  defp apply_tag_boost(pages, boost_tags, user) do
    page_ids = Enum.map(pages, & &1.page_id) |> Enum.uniq()

    if page_ids == [] do
      pages
    else
      tag_rows =
        Magus.Brain.PageTag
        |> Ash.Query.filter(page_id in ^page_ids and tag in ^boost_tags)
        |> Ash.read!(actor: user)

      boost_by_page =
        tag_rows
        |> Enum.group_by(& &1.page_id, & &1.tag)
        |> Map.new(fn {pid, ts} -> {pid, length(Enum.uniq(ts))} end)

      Enum.map(pages, fn page ->
        bonus = Map.get(boost_by_page, page.page_id, 0) * 0.5
        %{page | score: page.score + bonus}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — find_page implementation
  # ---------------------------------------------------------------------------

  defp find_in_brain(query, brain_id, brain_title, user) do
    trimmed = String.trim(query)
    lowered = String.downcase(trimmed)

    title_hits = title_hits(brain_id, trimmed, lowered, brain_title, user)
    title_ids = MapSet.new(title_hits, & &1.page_id)
    body_hits = body_fts_hits(brain_id, trimmed, brain_title, title_ids, user)

    title_hits ++ body_hits
  end

  # Exact title match → score 1.0; substring title match → 0.7.
  defp title_hits(brain_id, trimmed, lowered, brain_title, user) do
    require Ash.Query

    like_pattern = "%" <> escape_like(lowered) <> "%"

    # kind != :template (templates are meta, not findable content) and
    # is_nil(deleted_at) (the primary :read includes trashed rows).
    Magus.Brain.Page
    |> Ash.Query.filter(
      brain_id == ^brain_id and
        fragment("LOWER(?) LIKE ?", title, ^like_pattern) and
        kind != :template and is_nil(deleted_at)
    )
    |> Ash.Query.limit(50)
    |> Ash.read(actor: user)
    |> case do
      {:ok, pages} ->
        Enum.map(pages, fn page ->
          page_title_lower = String.downcase(page.title || "")

          score =
            cond do
              page_title_lower == lowered -> 1.0
              true -> 0.7
            end

          %{
            page_id: page.id,
            title: page.title || "Untitled",
            brain_id: brain_id,
            brain_title: brain_title,
            snippet: snippet_from_body(page.body, trimmed),
            score: score,
            match: :title
          }
        end)

      _ ->
        []
    end
  end

  # Full-text body match → score 0.4 (rank below any title hit). Excludes
  # pages already matched by title so duplicates don't compete.
  defp body_fts_hits(brain_id, trimmed, brain_title, exclude_ids, user) do
    case tsquery_from(trimmed) do
      "" ->
        []

      tsquery ->
        Magus.Brain.Page
        |> Ash.Query.filter(brain_id == ^brain_id and kind != :template and is_nil(deleted_at))
        |> Ash.Query.filter(fragment("search_vector @@ to_tsquery('english', ?)", ^tsquery))
        |> Ash.Query.limit(50)
        |> Ash.read(actor: user)
        |> case do
          {:ok, pages} ->
            pages
            |> Enum.reject(&MapSet.member?(exclude_ids, &1.id))
            |> Enum.map(fn page ->
              %{
                page_id: page.id,
                title: page.title || "Untitled",
                brain_id: brain_id,
                brain_title: brain_title,
                snippet: snippet_from_body(page.body, trimmed),
                score: 0.4,
                match: :body
              }
            end)

          _ ->
            []
        end
    end
  end

  defp tsquery_from(query) do
    query
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" & ")
  end

  defp snippet_from_body(nil, _query), do: nil
  defp snippet_from_body("", _query), do: nil

  defp snippet_from_body(body, query) do
    lowered_body = String.downcase(body)
    lowered_query = String.downcase(query)

    case :binary.match(lowered_body, lowered_query) do
      :nomatch ->
        body |> String.slice(0, 200) |> String.trim()

      {pos, len} ->
        start = max(pos - 60, 0)
        finish = min(pos + len + 140, byte_size(body))
        body |> binary_part(start, finish - start) |> String.trim()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — list_tags aggregation
  # ---------------------------------------------------------------------------

  # Tag rows are denormalized with `brain_id`, so a single query per brain
  # is enough; we still aggregate in Elixir to dedupe across `:frontmatter`
  # and `:inline` sources (frontmatter wins on tie). Per-brain query also
  # keeps the per-brain access check intact for cross-brain calls.
  defp aggregate_tags(brain_ids, brain_title_map, user) do
    brain_ids
    |> Enum.flat_map(fn brain_id ->
      case Brain.list_tags_for_brain(brain_id, actor: user) do
        {:ok, rows} ->
          rows
          |> Enum.group_by(& &1.tag)
          |> Enum.map(fn {tag, group} ->
            unique_page_ids = group |> Enum.map(& &1.page_id) |> Enum.uniq()

            %{
              tag: tag,
              count: length(unique_page_ids),
              brain_id: brain_id,
              brain_title: Map.get(brain_title_map, brain_id)
            }
          end)

        _ ->
          []
      end
    end)
    |> Enum.sort_by(fn t -> {t.brain_title || "", t.tag} end)
  end

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  defp escape_like(query) do
    query
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ---------------------------------------------------------------------------
  # Source formatting
  # ---------------------------------------------------------------------------

  defp format_source(source, ctx) do
    brain = load_brain_by_id(source.brain_id, ctx)
    emit_read_source_staleness_telemetry(source)

    %{
      action: "read_source",
      source_id: source.id,
      url: source.url,
      title: source.title,
      description: source.description,
      source_type: source.source_type,
      ingest_status: source.ingest_status,
      ingested_content: source.ingested_content,
      ingested_at: source.ingested_at,
      current: build_current(brain, nil)
    }
  end

  @source_staleness_threshold_days 7

  defp emit_read_source_staleness_telemetry(source) do
    case source.ingested_at do
      nil ->
        :ok

      ingested_at ->
        age_days = div(DateTime.diff(DateTime.utc_now(), ingested_at, :second), 86_400)

        if age_days > @source_staleness_threshold_days do
          :telemetry.execute(
            [:brain, :read_source, :staleness],
            %{age_days: age_days},
            %{
              brain_id: source.brain_id,
              source_id: source.id,
              url: source.url,
              ingest_status: source.ingest_status
            }
          )
        end

        :ok
    end
  end
end
