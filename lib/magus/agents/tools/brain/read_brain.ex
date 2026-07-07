defmodule Magus.Agents.Tools.Brain.ReadBrain do
  @moduledoc """
  Read-only brain tool. Supports listing brains and pages, finding
  pages by title or content, semantic search across pages and ingested
  sources, backlink lookup, tag exploration, AND reading page/source
  content (read_page, peek_page, read_source).

  All actions operate on the new markdown-body data model: page bodies
  are stored as a single `text` column on `Magus.Brain.Page`; per-chunk
  embeddings live in `Magus.Brain.PageChunk` (page bodies) and
  `Magus.Brain.SourceChunk` (ingested source content); wikilinks,
  source URLs, and tags are denormalized into `brain_page_links`,
  `brain_page_sources`, and `brain_page_tags`.

  This tool now also reads page and source content: `read_page` /
  `peek_page` (page bodies) and `read_source` (ingested sources). All
  writes (create_brain, write_page, edit_page, etc.) live on the
  sibling `Magus.Agents.Tools.Brain.EditBrain` tool.
  """

  use Jido.Action,
    name: "read_brain",
    description: """
    Read the user's knowledge brain: list pages, find by title or
    content, semantic search across pages + sources, backlinks, tag
    exploration, and read page/source content. Read-only.

    Actions:
    - list_brains: List all brains accessible to the user (personal or
      workspace, depending on context). Returns id, title, description,
      icon.
    - list_pages: List pages in a brain. Optional: brain_id,
      parent_page_id (children of this page), root_only (top-level
      only), tag (single tag string or list — pages must carry every
      tag). Returns page summaries (id, title, slug, parent, depth,
      position, has_children?). No body.
    - find_page: Find pages by title (substring, case-insensitive) and
      body full-text. Required: query. Optional: brain_id (omit or
      pass nil to search every accessible brain), tags (list of tag
      strings — pages matching any tag rank higher), limit (default
      20). Returns id, title, brain_id, brain_title, snippet, score.
    - search: Semantic search across page chunks and source chunks.
      Required: query (embedded server-side). Optional: brain_id (nil
      = cross-brain), limit (default 10), kind ("pages" | "sources" |
      "all", default "all"). Returns a unified flat list with kind,
      score, snippet, plus enough ids to follow up (page_id for page
      hits, source_id for source hits).
    - get_backlinks: Pages that wikilink to the given page. Required:
      page_id. Each result includes target_title_at_link_time so the
      caller can detect rename drift.
    - list_tags: All tags in scope with page counts. Optional:
      brain_id (omit or pass nil to span every accessible brain).
    - list_curation_candidates: Cheap maintenance scan of one brain for
      an automated curator. Returns metadata only, never page bodies
      (off_template reads bodies internally to diff headings, but its
      output stays metadata-only too): drifted (parent/index pages
      whose children changed after the parent was last edited), stale
      (untouched longer than stale_after_days), orphans (no inbound
      wikilinks), recently_changed, untyped (content pages with no
      frontmatter type), off_template (typed pages missing a heading
      their type's template declares), and unfiled (root pages with no
      parent and no inbound link). Optional: brain_id, stale_after_days
      (default 30), recent_days (default 7), limit (per-signal cap,
      default 20).
    - read_page: Read a page's full body. Required one of: page_id,
      page_title. Optional: start_line, end_line (1-indexed, inclusive)
      to read a slice with line-number prefixes.
    - peek_page: Lightweight preview — title + first 200 chars +
      line_count + last_modified_at. Required one of: page_id,
      page_title.
    - read_source: Read an ingested source (URL + extracted content).
      Required one of: source_id, (url + brain_id).

    Brain and page are auto-resolved from context when not specified. When you
    do name a brain, `brain_id` accepts the brain's id, slug, or title — the
    available brains (with ids) are listed in your context.
    """,
    schema: [
      action: [
        type: :string,
        required: true,
        doc:
          "Action: list_brains, list_pages, find_page, search, get_backlinks, list_tags, list_curation_candidates, read_page, peek_page, read_source"
      ],
      brain_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Brain id, slug, or title (the name the user mentions works). Pass nil with find_page / search / list_tags to search every accessible brain."
      ],
      page_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Page ID (get_backlinks, read_page, peek_page)"
      ],
      page_title: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Page title (read_page / peek_page lookup within brain)"
      ],
      query: [type: {:or, [:string, nil]}, default: nil, doc: "Search query (find_page, search)"],
      limit: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Max results. Defaults: find_page 20, search 10."
      ],
      parent_page_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Filter list_pages to direct children of this page"
      ],
      root_only: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "When true, list_pages returns only root pages (depth 0)"
      ],
      tag: [
        type: {:or, [:string, {:list, :string}, nil]},
        default: nil,
        doc:
          "list_pages filter: a tag string OR list of tags. Pages must carry every tag in the list."
      ],
      tags: [
        type: {:or, [{:list, :string}, nil]},
        default: nil,
        doc: "find_page boost: pages matching any of these tags rank higher."
      ],
      kind: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "search filter: pages | sources | all (default all)"
      ],
      stale_after_days: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc:
          "list_curation_candidates: a page is 'stale' if untouched for more than this many days (default 30)."
      ],
      recent_days: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "list_curation_candidates: window in days for 'recently changed' (default 7)."
      ],
      start_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "read_page slice start (1-indexed, inclusive)"
      ],
      end_line: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "read_page slice end (1-indexed, inclusive)"
      ],
      source_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "read_source: source row id"
      ],
      url: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "read_source: source URL (lookup within brain_id)"
      ]
    ]

  require Logger
  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Hierarchy
  alias Magus.Agents.Tools.Brain.BrainResolver
  alias Magus.Files.EmbeddingModel

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, tool_error: 3]

  def display_name, do: "Reading brain..."

  def summarize_output(%{error: error}), do: "Error: #{error}"

  def summarize_output(%{action: "read_page", page_title: t}), do: "Read page: #{t}"
  def summarize_output(%{action: "peek_page", page_title: t}), do: "Peeked: #{t}"
  def summarize_output(%{action: "read_source"}), do: "Read source"

  def summarize_output(%{action: "find_page", count: 0, hint: hint}),
    do: "No matching pages. #{hint}"

  def summarize_output(%{action: "find_page", count: 0}),
    do: "No matching pages"

  def summarize_output(%{action: "find_page", count: n, hint: hint}),
    do: "Found #{n} matching page(s). #{hint}"

  def summarize_output(%{action: "find_page", count: n}),
    do: "Found #{n} matching page(s)"

  def summarize_output(%{action: "list_brains", count: 0}),
    do: "No brains found"

  def summarize_output(%{action: "list_brains", count: n}),
    do: "Found #{n} brain(s)"

  def summarize_output(%{action: "list_pages", count: n, hint: hint}),
    do: "#{n} pages. #{hint}"

  def summarize_output(%{action: "list_pages", count: n}),
    do: "#{n} pages"

  def summarize_output(%{action: "search", count: 0, hint: hint}),
    do: "No results. #{hint}"

  def summarize_output(%{action: "search", count: 0}),
    do: "No results"

  def summarize_output(%{action: "search", count: n, hint: hint}) when is_binary(hint),
    do: "#{n} result(s). #{hint}"

  def summarize_output(%{action: "search", count: n}), do: "#{n} result(s)"

  def summarize_output(%{action: "get_backlinks", count: 0}),
    do: "No backlinks"

  def summarize_output(%{action: "get_backlinks", count: n, hint: hint}),
    do: "#{n} backlink(s). #{hint}"

  def summarize_output(%{action: "get_backlinks", count: n}),
    do: "#{n} backlink(s)"

  def summarize_output(%{action: "list_tags", count: 0}),
    do: "No tags"

  def summarize_output(%{action: "list_tags", count: n}),
    do: "#{n} tag(s)"

  def summarize_output(%{action: "list_curation_candidates", counts: c}),
    do:
      "Curation candidates: #{c.drifted} drifted, #{c.stale} stale, #{c.orphans} orphan(s), #{c.recently_changed} recently changed, #{c.untyped} untyped, #{c.off_template} off_template, #{c.unfiled} unfiled"

  def summarize_output(%{summary: summary}), do: summary
  def summarize_output(%{hint: hint}) when is_binary(hint), do: hint
  def summarize_output(_), do: "Completed"

  @valid_actions ~w(list_brains list_pages find_page search get_backlinks list_tags
                    list_curation_candidates read_page peek_page read_source)

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :user]) do
      {:ok, ctx} ->
        action = get_param(params, :action)
        dispatch(action, params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp dispatch(action, _params, _ctx, _context) when action not in @valid_actions do
    valid = Enum.join(@valid_actions, ", ")

    if is_nil(action) do
      {:ok, %{error: "Missing required parameter: action. Must be one of: #{valid}"}}
    else
      {:ok, %{error: "Unknown action '#{action}'. Must be one of: #{valid}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # list_brains
  # ---------------------------------------------------------------------------

  defp dispatch("list_brains", _params, ctx, context) do
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

  defp dispatch("list_pages", params, ctx, context) do
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

  defp dispatch("find_page", params, ctx, context) do
    query = get_param(params, :query)

    if is_nil(query) or query == "" do
      {:ok, %{error: "Missing required parameter: query"}}
    else
      limit = get_param(params, :limit) || 20
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
  # search
  # ---------------------------------------------------------------------------

  defp dispatch("search", params, ctx, context) do
    query = get_param(params, :query)

    cond do
      is_nil(query) or query == "" ->
        {:ok, %{error: "Missing required parameter: query"}}

      true ->
        limit = get_param(params, :limit) || 10
        kind = normalize_kind(get_param(params, :kind))
        brain_pairs = resolve_brain_pairs(params, context, ctx)

        cond do
          brain_pairs == [] ->
            {:ok,
             %{
               action: "search",
               count: 0,
               results: [],
               hint: "No accessible brains."
             }}

          true ->
            do_search(query, brain_pairs, limit, kind, ctx)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # get_backlinks
  # ---------------------------------------------------------------------------

  defp dispatch("get_backlinks", params, ctx, _context) do
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

  defp dispatch("list_tags", params, ctx, context) do
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
  # list_curation_candidates
  # ---------------------------------------------------------------------------

  defp dispatch("list_curation_candidates", params, ctx, context) do
    case BrainResolver.resolve_brain_id(context, params) do
      {:ok, brain_id} ->
        stale_after_days = get_param(params, :stale_after_days) || 30
        recent_days = get_param(params, :recent_days) || 7
        limit = get_param(params, :limit) || 20
        curation_candidates(brain_id, stale_after_days, recent_days, limit, ctx.user)

      {:error, msg} ->
        {:ok, %{error: msg}}
    end
  end

  # ---------------------------------------------------------------------------
  # read_page
  # ---------------------------------------------------------------------------

  defp dispatch("read_page", params, ctx, context) do
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

  defp dispatch("peek_page", params, ctx, context) do
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

  defp dispatch("read_source", params, ctx, context) do
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

  # Cheap, body-free maintenance scan. Everything is derived from a single
  # metadata-only page read plus one backlink query: no embeddings, no LLM,
  # and crucially no page bodies. The agent reads bodies only for the pages
  # it decides to act on. Policy (what to actually do about each signal)
  # lives in the curator agent's instructions, not here.
  #
  # Cost note: the page read pulls every non-trashed page row in the brain
  # (id/title/parent/updated_at only — no bodies), so the scan is O(pages in
  # brain) in memory. `limit` caps the OUTPUT per signal, not the scan itself.
  # That trade is intentional for a periodic maintenance pass.
  defp curation_candidates(brain_id, stale_after_days, recent_days, limit, user) do
    page_query =
      Magus.Brain.Page
      |> Ash.Query.filter(brain_id == ^brain_id)
      |> Ash.Query.select([:id, :title, :parent_page_id, :updated_at, :kind, :frontmatter])

    case Ash.read(page_query, actor: user) do
      {:ok, []} ->
        {:ok, empty_curation_result(brain_id)}

      {:ok, pages} ->
        now = DateTime.utc_now()
        linked_targets = linked_target_ids(pages, user)

        drifted = drifted_candidates(pages)
        stale = stale_candidates(pages, now, stale_after_days)
        orphans = orphan_candidates(pages, linked_targets)
        recent = recent_candidates(pages, now, recent_days)
        untyped = untyped_candidates(pages)
        unfiled = unfiled_candidates(pages, linked_targets)
        off_template = off_template_candidates(pages, brain_id, limit, user)

        # `count` is the deduped UNION of the actionable signals (a page can be
        # both stale and an orphan but counts once). recently_changed is
        # informational, not "needs curation", so it is excluded from count.
        total =
          [drifted, stale, orphans, untyped, unfiled, off_template]
          |> Enum.flat_map(fn list -> Enum.map(list, & &1.page_id) end)
          |> Enum.uniq()
          |> length()

        {:ok,
         %{
           action: "list_curation_candidates",
           brain_id: brain_id,
           count: total,
           counts: %{
             drifted: length(drifted),
             stale: length(stale),
             orphans: length(orphans),
             recently_changed: length(recent),
             untyped: length(untyped),
             off_template: length(off_template),
             unfiled: length(unfiled)
           },
           drifted: Enum.take(drifted, limit),
           stale: Enum.take(stale, limit),
           orphans: Enum.take(orphans, limit),
           recently_changed: Enum.take(recent, limit),
           untyped: Enum.take(untyped, limit),
           off_template: Enum.take(off_template, limit),
           unfiled: Enum.take(unfiled, limit),
           hint:
             "Metadata only — no page bodies. Read just the pages you intend to act on with read_brain.read_page. 'drifted' = parent/index pages whose children changed after the parent was last edited; 'untyped' = content pages with no frontmatter type; 'off_template' = typed pages missing headings their type's template declares; 'unfiled' = root pages with no parent and no inbound link; what to do about each signal is decided by your instructions."
         }}

      {:error, err} ->
        {:ok,
         %{
           error:
             tool_error(
               "scan brain for curation candidates",
               err,
               "Verify brain_id with read_brain list_brains."
             )
         }}
    end
  end

  defp empty_curation_result(brain_id) do
    %{
      action: "list_curation_candidates",
      brain_id: brain_id,
      count: 0,
      counts: %{
        drifted: 0,
        stale: 0,
        orphans: 0,
        recently_changed: 0,
        untyped: 0,
        off_template: 0,
        unfiled: 0
      },
      drifted: [],
      stale: [],
      orphans: [],
      recently_changed: [],
      untyped: [],
      off_template: [],
      unfiled: [],
      hint: "This brain has no pages yet."
    }
  end

  # One query: every backlink whose target is a page in this brain. We only
  # need the set of linked target ids to find orphans (pages nobody links to).
  #
  # Actor note: reads PageLink as `user`. For the AI curator that is the
  # AiAgent, which the PageLink read policy lets see every link (IsAiAgent
  # bypass), so orphan detection is complete. For an interactive human actor
  # the policy scopes by the link's source page; that only hides a link whose
  # SOURCE sits in a brain the user cannot read — impossible for the in-brain
  # wikilinks this targets, so orphans stay accurate in practice. If
  # cross-brain links are ever introduced, revisit (read with the AI actor).
  defp linked_target_ids(pages, user) do
    page_ids = Enum.map(pages, & &1.id)

    Magus.Brain.PageLink
    |> Ash.Query.filter(target_page_id in ^page_ids)
    |> Ash.read!(actor: user)
    |> MapSet.new(& &1.target_page_id)
  end

  # A parent/index page has "drifted" when at least one child was edited more
  # recently than the parent itself. updated_at is a coarse proxy (a title or
  # position change also bumps it), which is acceptable for a cheap signal:
  # the agent reads the page to judge whether the rollup is actually out of date.
  defp drifted_candidates(pages) do
    by_parent = Enum.group_by(pages, & &1.parent_page_id)

    pages
    |> Enum.filter(&Map.has_key?(by_parent, &1.id))
    |> Enum.map(fn parent ->
      changed =
        by_parent
        |> Map.get(parent.id, [])
        |> Enum.filter(&(DateTime.compare(&1.updated_at, parent.updated_at) == :gt))

      {parent, changed}
    end)
    |> Enum.reject(fn {_parent, changed} -> changed == [] end)
    |> Enum.map(fn {parent, changed} ->
      last = changed |> Enum.map(& &1.updated_at) |> Enum.max(DateTime)
      {parent, changed, last}
    end)
    |> Enum.sort_by(fn {_parent, _changed, last} -> last end, {:desc, DateTime})
    |> Enum.map(fn {parent, changed, last} ->
      %{
        page_id: parent.id,
        title: parent.title || "Untitled",
        updated_at: DateTime.to_iso8601(parent.updated_at),
        last_child_change_at: DateTime.to_iso8601(last),
        changed_children: Enum.map(changed, &%{page_id: &1.id, title: &1.title || "Untitled"})
      }
    end)
  end

  defp stale_candidates(pages, now, stale_after_days) do
    threshold = DateTime.add(now, -stale_after_days * 86_400, :second)

    pages
    |> Enum.filter(&(DateTime.compare(&1.updated_at, threshold) == :lt))
    |> Enum.sort_by(& &1.updated_at, {:asc, DateTime})
    |> Enum.map(fn p ->
      %{
        page_id: p.id,
        title: p.title || "Untitled",
        updated_at: DateTime.to_iso8601(p.updated_at),
        days_since: div(DateTime.diff(now, p.updated_at, :second), 86_400)
      }
    end)
  end

  defp orphan_candidates(pages, linked_targets) do
    pages
    |> Enum.reject(&MapSet.member?(linked_targets, &1.id))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map(&%{page_id: &1.id, title: &1.title || "Untitled"})
  end

  defp recent_candidates(pages, now, recent_days) do
    threshold = DateTime.add(now, -recent_days * 86_400, :second)

    pages
    |> Enum.filter(&(DateTime.compare(&1.updated_at, threshold) != :lt))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map(
      &%{
        page_id: &1.id,
        title: &1.title || "Untitled",
        updated_at: DateTime.to_iso8601(&1.updated_at)
      }
    )
  end

  # Content pages (`kind: :page`, i.e. not templates) with a blank or missing
  # frontmatter `type`. Metadata-only: `frontmatter` is already in the
  # curation query's select, so no extra read.
  defp untyped_candidates(pages) do
    pages
    |> Enum.filter(&(&1.kind == :page and blank?(page_type(&1))))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map(&%{page_id: &1.id, title: &1.title || "Untitled"})
  end

  # Root-level orphans: no parent AND no inbound wikilink. A page with a
  # parent is "filed" under it regardless of backlinks, so this is a strict
  # subset of `orphan_candidates/2` (parent-less orphans only).
  defp unfiled_candidates(pages, linked_targets) do
    pages
    |> Enum.filter(&is_nil(&1.parent_page_id))
    |> Enum.reject(&MapSet.member?(linked_targets, &1.id))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.map(&%{page_id: &1.id, title: &1.title || "Untitled"})
  end

  # Cheap heading-set diff against the page's type template, no LLM. Bounded
  # to `limit` typed pages so the body reads (the one place this scan departs
  # from metadata-only) stay capped regardless of brain size. For each
  # candidate: resolve its template by case-insensitive title match against
  # `frontmatter["type"]` (same rule as `brain_guide.ex`'s
  # `resolve_type_template/3`), then flag it if the template declares a
  # heading the page's body doesn't have. Pages whose type has no matching
  # template are skipped (nothing to diff against).
  defp off_template_candidates(pages, brain_id, limit, user) do
    typed =
      pages
      |> Enum.filter(&(&1.kind == :page and not blank?(page_type(&1))))
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
      |> Enum.take(limit)

    case typed do
      [] ->
        []

      _ ->
        templates =
          case Brain.templates_for_brain(brain_id, actor: user) do
            {:ok, templates} -> templates
            _ -> []
          end

        template_headings_by_title =
          Map.new(templates, fn t -> {String.downcase(t.title || ""), heading_set(t.body)} end)

        bodies_by_id = page_bodies(Enum.map(typed, & &1.id), user)

        typed
        |> Enum.flat_map(fn page ->
          type = page_type(page)
          template_headings = Map.get(template_headings_by_title, String.downcase(type))

          case template_headings do
            nil ->
              []

            declared ->
              page_headings = heading_set(Map.get(bodies_by_id, page.id))
              missing = MapSet.difference(declared, page_headings)

              if MapSet.size(missing) == 0 do
                []
              else
                [
                  %{
                    page_id: page.id,
                    title: page.title || "Untitled",
                    type: type,
                    missing_headings: Enum.sort(MapSet.to_list(missing))
                  }
                ]
              end
          end
        end)
    end
  end

  # `frontmatter["type"]`, trimmed. Mirrors `brain_guide.ex`'s `page_type/1`.
  defp page_type(%{frontmatter: fm}) when is_map(fm) do
    case Map.get(fm, "type") do
      type when is_binary(type) -> String.trim(type)
      _ -> nil
    end
  end

  defp page_type(_), do: nil

  # Loads just the `body` for the given page ids, bounded to the typed pages
  # `off_template_candidates/4` actually checks (not the whole brain).
  defp page_bodies(page_ids, user) do
    Magus.Brain.Page
    |> Ash.Query.filter(id in ^page_ids)
    |> Ash.Query.select([:id, :body])
    |> Ash.read(actor: user)
    |> case do
      {:ok, pages} -> Map.new(pages, &{&1.id, &1.body})
      _ -> %{}
    end
  end

  # ATX section headings (`##` through `######`), text trimmed, `#` markers
  # stripped. Excludes level-1 (`# Title`): every template and every page
  # opens with its own `# <own title>` line, which never matches across a
  # template/instance pair by design (a page's title isn't the template's
  # title) — diffing it would flag every typed page as off_template
  # regardless of its actual sections. Level is otherwise ignored for the
  # diff (a template's `## Method` matches a page's `### Method` just as
  # well) since the goal is "does the section exist", not exact structural
  # parity.
  defp heading_set(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&heading_text/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp heading_set(_), do: MapSet.new()

  defp heading_text(line) do
    case Regex.run(~r/^\#{2,6}\s+(.+?)\s*$/, line) do
      [_, text] -> text
      nil -> nil
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
  # Helpers — brain pair resolution (cross-brain support)
  # ---------------------------------------------------------------------------

  # find_page / search / list_tags accept either an explicit brain_id, or
  # explicit `brain_id: nil` to span every accessible brain, or no key at
  # all (in which case we honor the active context brain_id and only fall
  # back to cross-brain when context too is unset). We always return
  # `[{brain_id, brain_title}]` so downstream code can decorate results
  # with the originating brain.
  defp resolve_brain_pairs(params, context, ctx) do
    {has_key?, explicit_value} = fetch_brain_param(params)

    cond do
      has_key? and is_binary(explicit_value) and explicit_value != "" ->
        # Route through the resolver so the explicit value can be a brain id,
        # slug, or title (and is workspace-scoped), then fetch the brain.
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            case Brain.get_brain(brain_id, actor: ctx.user) do
              {:ok, brain} -> [{brain.id, brain.title}]
              _ -> []
            end

          _ ->
            []
        end

      has_key? and is_nil(explicit_value) ->
        list_accessible_brain_pairs(context, ctx)

      true ->
        # Key omitted entirely: prefer the active context brain when set,
        # else span every accessible brain so the tool stays useful in
        # contexts without a pane.
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            case Brain.get_brain(brain_id, actor: ctx.user) do
              {:ok, brain} -> [{brain.id, brain.title}]
              _ -> []
            end

          _ ->
            list_accessible_brain_pairs(context, ctx)
        end
    end
  end

  defp fetch_brain_param(params) do
    cond do
      Map.has_key?(params, :brain_id) -> {true, Map.get(params, :brain_id)}
      Map.has_key?(params, "brain_id") -> {true, Map.get(params, "brain_id")}
      true -> {false, nil}
    end
  end

  defp list_accessible_brain_pairs(context, ctx) do
    case BrainResolver.resolve_brain_ids(context, ctx.user) do
      {:ok, pairs} -> pairs
      _ -> []
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

    Magus.Brain.Page
    |> Ash.Query.filter(
      brain_id == ^brain_id and
        fragment("LOWER(?) LIKE ?", title, ^like_pattern)
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
        |> Ash.Query.filter(brain_id == ^brain_id)
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
  # Helpers — semantic search (PageChunk + SourceChunk)
  # ---------------------------------------------------------------------------

  defp normalize_kind(nil), do: :all
  defp normalize_kind("all"), do: :all
  defp normalize_kind("pages"), do: :pages
  defp normalize_kind("sources"), do: :sources
  # Any other value falls back to :all rather than failing the dispatch —
  # the LLM may invent labels and the tool stays usable.
  defp normalize_kind(_), do: :all

  defp do_search(query, brain_pairs, limit, kind, ctx) do
    case EmbeddingModel.embed(query) do
      {:ok, embedding} ->
        results =
          brain_pairs
          |> Enum.flat_map(fn {brain_id, brain_title} ->
            page_hits =
              if kind in [:all, :pages] do
                fetch_page_chunk_hits(brain_id, brain_title, embedding, limit, ctx.user)
              else
                []
              end

            source_hits =
              if kind in [:all, :sources] do
                fetch_source_chunk_hits(brain_id, brain_title, embedding, limit, ctx.user)
              else
                []
              end

            page_hits ++ source_hits
          end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        hint =
          cond do
            results == [] and length(brain_pairs) > 1 ->
              "No semantic matches across #{length(brain_pairs)} brain(s). Hint: try a more descriptive query, or set kind to scope the search."

            results == [] ->
              "No semantic matches. Hint: the index may not be embedded yet, or try a more descriptive query."

            true ->
              "Results sorted by similarity score. Each carries enough ids for read_brain.read_page / read_source follow-up."
          end

        {:ok,
         %{
           action: "search",
           query: query,
           count: length(results),
           kind: Atom.to_string(kind),
           results: results,
           hint: hint
         }}

      {:error, reason} ->
        Logger.warning("Embedding failed for read_brain search: #{inspect(reason)}")

        {:ok,
         %{
           action: "search",
           query: query,
           count: 0,
           kind: Atom.to_string(kind),
           results: [],
           hint:
             "Semantic search unavailable (embedding API not reachable). Hint: try read_brain find_page for title/body keyword matching."
         }}
    end
  end

  defp fetch_page_chunk_hits(brain_id, brain_title, embedding, limit, user) do
    case Brain.search_page_chunks(brain_id, embedding, %{limit: limit}, actor: user) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          page = chunk.page

          %{
            kind: "page_chunk",
            score: 1.0 - (chunk.vector_distance || 0.0),
            snippet: String.slice(chunk.content || "", 0, 500),
            brain_id: brain_id,
            brain_title: brain_title,
            page_id: page && page.id,
            page_title: page && (page.title || "Untitled"),
            source_id: nil,
            source_url: nil
          }
        end)

      _ ->
        []
    end
  end

  defp fetch_source_chunk_hits(brain_id, brain_title, embedding, limit, user) do
    case Brain.search_source_chunks(brain_id, embedding, %{limit: limit}, actor: user) do
      {:ok, chunks} ->
        Enum.map(chunks, fn chunk ->
          source = chunk.source

          %{
            kind: "source_chunk",
            score: 1.0 - (chunk.vector_distance || 0.0),
            snippet: String.slice(chunk.content || "", 0, 500),
            brain_id: brain_id,
            brain_title: brain_title,
            page_id: nil,
            page_title: nil,
            source_id: source && source.id,
            source_url: source && source.url
          }
        end)

      _ ->
        []
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
  # read_page / peek_page helpers
  #
  # These are duplicated from `Magus.Agents.Tools.Brain.EditBrain` so this
  # read tool stays self-contained. EditBrain keeps its own copies because
  # its write paths still use them. A future shared Support module could
  # collapse the duplication.
  # ---------------------------------------------------------------------------

  defp resolve_page_for_read(context, params, brain_id, ctx) do
    cond do
      page_id = get_param(params, :page_id) ->
        Brain.get_page(page_id, actor: ctx.user)

      page_title = get_param(params, :page_title) ->
        cond do
          slash_path?(page_title) ->
            segments = parse_slash(page_title)

            case resolve_leaf_via_chain(brain_id, segments, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: #{page_title}"}
            end

          true ->
            case find_existing_page(brain_id, page_title, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: '#{page_title}'"}
            end
        end

      pane_page_id = Map.get(context, :brain_page_id) || Map.get(context, "brain_page_id") ->
        Brain.get_page(pane_page_id, actor: ctx.user)

      true ->
        {:error,
         "No page specified. Provide page_id, page_title, or open a page in the brain pane."}
    end
  end

  defp find_existing_page(brain_id, title, ctx) do
    case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
      {:ok, [page | _]} -> {:ok, page}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  defp parse_slash(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp slash_path?(title) when is_binary(title) do
    title |> parse_slash() |> length() |> Kernel.>(1)
  end

  defp slash_path?(_), do: false

  defp resolve_leaf_via_chain(brain_id, segments, ctx) do
    walk_segments(brain_id, segments, nil, ctx)
  end

  defp walk_segments(_brain_id, [], _parent, _ctx), do: :not_found

  defp walk_segments(brain_id, [last], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, last, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> {:ok, page}
        end

      _ ->
        :not_found
    end
  end

  defp walk_segments(brain_id, [head | rest], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, head, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> walk_segments(brain_id, rest, page.id, ctx)
        end

      _ ->
        :not_found
    end
  end

  defp slice_body(body, nil, nil, _total), do: {:ok, body}

  defp slice_body(body, start_line, end_line, total) when is_integer(start_line) do
    end_line = end_line || total

    cond do
      start_line < 1 ->
        {:error, "start_line must be >= 1, got #{start_line}."}

      start_line > total ->
        {:error, "start_line #{start_line} exceeds line_count #{total}."}

      end_line < start_line ->
        {:error, "end_line (#{end_line}) must be >= start_line (#{start_line})."}

      true ->
        clamped = min(end_line, total)

        lines =
          body
          |> String.split("\n")
          |> Enum.slice((start_line - 1)..(clamped - 1))
          |> Enum.with_index(start_line)
          |> Enum.map(fn {line, idx} -> "#{idx}: #{line}" end)
          |> Enum.join("\n")

        {:ok, lines}
    end
  end

  defp slice_body(body, _, end_line, total) when is_integer(end_line),
    do: slice_body(body, 1, end_line, total)

  defp slice_body(body, _, _, _), do: {:ok, body}

  defp line_count(""), do: 0
  defp line_count(body) when is_binary(body), do: length(String.split(body, "\n"))
  defp line_count(_), do: 0

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

  # ---------------------------------------------------------------------------
  # `current` echo + brain loading
  # ---------------------------------------------------------------------------

  defp build_current(nil, nil), do: %{}

  defp build_current(brain, nil) when is_map(brain) do
    %{brain_id: brain.id, brain_title: brain.title}
  end

  defp build_current(nil, page) when is_map(page) do
    %{page_id: page.id, page_title: page.title}
  end

  defp build_current(brain, page) when is_map(brain) and is_map(page) do
    %{
      brain_id: brain.id,
      brain_title: brain.title,
      page_id: page.id,
      page_title: page.title
    }
  end

  defp load_brain(nil, _ctx), do: nil

  defp load_brain(%{brain_id: brain_id}, ctx) do
    load_brain_by_id(brain_id, ctx)
  end

  defp load_brain(_, _), do: nil

  defp load_brain_by_id(nil, _ctx), do: nil

  defp load_brain_by_id(brain_id, ctx) do
    case Brain.get_brain(brain_id, actor: ctx.user) do
      {:ok, brain} -> brain
      _ -> nil
    end
  end

  defp build_breadcrumb(page, ctx) do
    case Brain.list_pages(page.brain_id, actor: ctx.user) do
      {:ok, all_pages} -> Hierarchy.build_breadcrumb(page, all_pages)
      _ -> page.title
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
