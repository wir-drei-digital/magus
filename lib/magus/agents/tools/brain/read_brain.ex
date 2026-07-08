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

  This module is a thin dispatcher: the schema and valid actions live
  here, but each action's handler logic lives in a concern submodule
  under `ReadBrain.*`:

    * `ReadBrain.Reads` — list_brains, list_pages, find_page,
      get_backlinks, list_tags, read_page, peek_page, read_source
    * `ReadBrain.Search` — search (semantic search over page/source
      chunks)
    * `ReadBrain.Curation` — list_curation_candidates
    * `ReadBrain.Support` — shared internals across the above (the
      `current` echo, page lookup, cross-brain resolution)
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
      their type's template declares), dangling_type (typed pages whose
      type matches no live template, e.g. after a template rename or
      trash), and unfiled (root pages with no parent and no inbound
      link). Optional: brain_id, stale_after_days (default 30),
      recent_days (default 7), limit (per-signal cap, default 20).
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

  alias Magus.Agents.Tools.Brain.ReadBrain.Reads
  alias Magus.Agents.Tools.Brain.ReadBrain.Search
  alias Magus.Agents.Tools.Brain.ReadBrain.Curation

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2]

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
      "Curation candidates: #{c.drifted} drifted, #{c.stale} stale, #{c.orphans} orphan(s), #{c.recently_changed} recently changed, #{c.untyped} untyped, #{c.off_template} off_template, #{Map.get(c, :dangling_type, 0)} dangling_type, #{c.unfiled} unfiled"

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
  # Reads.* actions -> ReadBrain.Reads
  # ---------------------------------------------------------------------------

  defp dispatch("list_brains", params, ctx, context) do
    Reads.handle_list_brains(params, ctx, context)
  end

  defp dispatch("list_pages", params, ctx, context) do
    Reads.handle_list_pages(params, ctx, context)
  end

  defp dispatch("find_page", params, ctx, context) do
    Reads.handle_find_page(params, ctx, context)
  end

  defp dispatch("get_backlinks", params, ctx, _context) do
    Reads.handle_get_backlinks(params, ctx)
  end

  defp dispatch("list_tags", params, ctx, context) do
    Reads.handle_list_tags(params, ctx, context)
  end

  defp dispatch("read_page", params, ctx, context) do
    Reads.handle_read_page(params, ctx, context)
  end

  defp dispatch("peek_page", params, ctx, context) do
    Reads.handle_peek_page(params, ctx, context)
  end

  defp dispatch("read_source", params, ctx, context) do
    Reads.handle_read_source(params, ctx, context)
  end

  # ---------------------------------------------------------------------------
  # search -> ReadBrain.Search
  # ---------------------------------------------------------------------------

  defp dispatch("search", params, ctx, context) do
    Search.handle_search(params, ctx, context)
  end

  # ---------------------------------------------------------------------------
  # list_curation_candidates -> ReadBrain.Curation
  # ---------------------------------------------------------------------------

  defp dispatch("list_curation_candidates", params, ctx, context) do
    Curation.handle_list_curation_candidates(params, ctx, context)
  end
end
