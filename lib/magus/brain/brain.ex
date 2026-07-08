defmodule Magus.Brain do
  @moduledoc """
  Brain domain: markdown-native knowledge pages and ingested sources, with
  `[[wikilink]]` backlinks, frontmatter tags, and pgvector search over page
  and source chunks. The markdown body is the single source of truth.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPaperTrail.Domain, AshTypescript.Rpc]

  paper_trail do
    include_versions? true
  end

  # Read-only exposure for the SvelteKit workbench's brain-page companion
  # (iteration 4). Writes stay LiveView-only until the editor port
  # (iteration 7).
  typescript_rpc do
    resource Magus.Brain.Page do
      rpc_action :list_brain_page_versions, :versions

      # Iteration 7: tree reads + markdown editing (update_body carries the
      # optimistic-lock base_version; a stale version comes back as an RPC
      # error the SPA resolves by refetching).
      rpc_action :root_brain_pages, :root_pages
      rpc_action :brain_page_children, :children_of
      rpc_action :trashed_brain_pages, :trashed
      rpc_action :brain_pages, :for_brain
      rpc_action :brain_templates, :templates_for_brain
      rpc_action :save_brain_page_prosemirror, :save_prosemirror
      rpc_action :create_brain_page, :create
      rpc_action :brain_page_version_diff, :version_diff
      rpc_action :brain_page_version_body, :version_body
      rpc_action :brain_page_guide, :guide_for_page
      rpc_action :rename_brain_page, :update_title
      rpc_action :update_brain_page_body, :update_body
      rpc_action :move_brain_page, :move_to_parent
      rpc_action :trash_brain_page, :soft_delete

      rpc_action :restore_brain_page, :restore do
        # The default record loader is the primary :read, which filters out
        # trashed rows — exactly the rows restore targets. Loading bypasses
        # policies here, but the :restore update itself stays policy-gated
        # (BrainAccessFilter editor), so strangers still get forbidden.
        read_action :read_including_trashed
      end

      rpc_action :get_brain_page, :read do
        get_by [:id]
      end
    end

    resource Magus.Brain.PageLink do
      rpc_action :list_page_backlinks, :backlinks_for
    end

    resource Magus.Brain.PageSource do
      rpc_action :list_page_sources, :for_page
    end

    # No direct RPC actions — typed so PageSource's `source` and Page's
    # `brain` relationships can be field-selected.
    resource Magus.Brain.Source do
    end

    resource Magus.Brain.BrainResource do
      rpc_action :my_brains, :list_for_user
      rpc_action :workspace_brains, :list_for_workspace
      rpc_action :create_brain, :create
      rpc_action :update_brain, :update
      rpc_action :share_brain_to_team, :share_to_team
      rpc_action :unshare_brain_from_team, :unshare_from_team
    end
  end

  resources do
    resource Magus.Brain.BrainResource do
      define :create_brain, action: :create
      define :get_brain, action: :read, get_by: [:id]
      define :list_brains, action: :list_for_user
      define :personal_brains, action: :list_for_user
      define :list_brains_for_workspace, action: :list_for_workspace, args: [:workspace_id]
      define :update_brain, action: :update
      define :set_brain_instructions, action: :set_instructions
      define :archive_brain, action: :archive
      define :destroy_brain, action: :destroy
    end

    resource Magus.Brain.Page do
      define :create_page, action: :create, args: [:brain_id]
      define :create_page_as_external_agent, action: :create_as_external_agent, args: [:brain_id]
      define :get_page, action: :read, get_by: [:id]
      define :list_pages, action: :for_brain, args: [:brain_id]
      define :templates_for_brain, action: :templates_for_brain, args: [:brain_id]
      define :update_page_title, action: :update_title
      define :update_page_body, action: :update_body
      define :find_page_by_title, action: :by_title_in_brain, args: [:brain_id, :title]

      define :find_page_by_title_ci,
        action: :by_title_in_brain_ci,
        args: [:brain_id, :title]

      define :destroy_page, action: :destroy
      define :soft_delete_page, action: :soft_delete
      define :restore_page, action: :restore
      define :list_trashed_pages, action: :trashed, args: [:workspace_id]
      define :list_root_pages, action: :root_pages, args: [:brain_id]
      define :list_children_pages, action: :children_of, args: [:parent_page_id]
      define :move_page_to_parent, action: :move_to_parent
      define :page_guide, action: :guide_for_page, args: [:page_id]
    end

    resource Magus.Brain.Block do
      define :list_blocks, action: :for_page, args: [:page_id]
    end

    resource Magus.Brain.Page.Version

    resource Magus.Brain.Source do
      define :get_source, action: :read, get_by: [:id]
      define :list_sources, action: :for_brain, args: [:brain_id]
      define :find_source_by_url, action: :by_url, args: [:brain_id, :url]
      define :update_source, action: :update
      define :ingest_source, action: :ingest
    end

    resource Magus.Brain.PageChunk do
      define :list_page_chunks, action: :for_page, args: [:page_id]
      define :search_page_chunks, action: :semantic_search, args: [:brain_id, :query_embedding]
    end

    resource Magus.Brain.SourceChunk do
      define :list_source_chunks, action: :for_source, args: [:source_id]
      define :search_source_chunks, action: :semantic_search, args: [:brain_id, :query_embedding]
    end

    resource Magus.Brain.PageLink do
      define :list_backlinks, action: :backlinks_for, args: [:page_id]
      define :list_forward_links, action: :forward_links_for, args: [:page_id]
    end

    resource Magus.Brain.PageSource do
      define :list_page_sources, action: :for_page, args: [:page_id]
    end

    resource Magus.Brain.PageTag do
      define :list_tags_for_page, action: :for_page, args: [:page_id]
      define :list_tags_for_brain, action: :for_brain, args: [:brain_id]
      define :pages_with_tag, action: :pages_with_tag, args: [:brain_id, :tag]
    end
  end

  @doc """
  Returns the per-brain activity feed (page-level edits sourced from
  `Magus.Brain.Page.Version`). See `Magus.Brain.Activity` for the entry
  shape. Newest first, defaults to 50 entries.
  """
  @spec list_brain_activity(String.t(), keyword()) :: [map()]
  defdelegate list_brain_activity(brain_id, opts \\ []), to: Magus.Brain.Activity

  @doc """
  Page-scoped version history (newest first). See `Magus.Brain.PageHistory`
  for the entry shape. Reads versions with `authorize?: false`; the caller
  must already hold the page authorized for the actor.
  """
  @spec list_page_versions(String.t(), keyword()) :: [map()]
  defdelegate list_page_versions(page_id, opts \\ []),
    to: Magus.Brain.PageHistory,
    as: :list_for_page

  @doc """
  Diff data for one page version against the prior version. Returns
  `{:ok, map}` or `:error`. See `Magus.Brain.PageHistory.version_diff/2`.
  """
  @spec page_version_diff(String.t(), String.t()) :: {:ok, map()} | :error
  defdelegate page_version_diff(page_id, version_id),
    to: Magus.Brain.PageHistory,
    as: :version_diff

  @doc """
  Full snapshot body of one page version (for restore). Returns
  `{:ok, binary}` or `:error`.
  """
  @spec page_version_body(String.t(), String.t()) :: {:ok, binary()} | :error
  defdelegate page_version_body(page_id, version_id),
    to: Magus.Brain.PageHistory,
    as: :version_body_for

  @doc """
  Pure semantic search across `PageChunk` and `SourceChunk`. Returns a
  unified list of hits sorted by score descending, capped at limit.

  Pass `brain_id: nil` (or omit) to span every brain the actor can
  access; pass a uuid to scope to a single brain.

  Hit shape:

    * `%{kind: :page_chunk, score, brain_id, page_id, snippet}`
    * `%{kind: :source_chunk, score, brain_id, source_id, snippet}`
  """
  @spec search_chunks(String.t() | nil, [float()], keyword()) :: [map()]
  def search_chunks(brain_id, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    actor = Keyword.fetch!(opts, :actor)
    brain_ids = resolve_brain_ids(brain_id, actor)

    page_hits = run_page_chunk_search(brain_ids, query_embedding, limit, actor)
    source_hits = run_source_chunk_search(brain_ids, query_embedding, limit, actor)

    (page_hits ++ source_hits)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Postgres full-text search over `brain_pages.search_vector` (the
  Phase A GIN-indexed `tsvector`). Returns a list of:

      %{
        kind: :page,
        page_id: uuid,
        brain_id: uuid,
        title: binary | nil,
        snippet: binary,
        rank: float
      }

  Sorted by `ts_rank_cd` descending. `brain_id == nil` spans every
  brain the actor can access; otherwise scopes to the supplied brain.
  Returns `[]` if the query reduces to no usable tokens.
  """
  @spec search_pages_text(String.t() | nil, binary(), keyword()) :: [map()]
  def search_pages_text(brain_id, query, opts) when is_binary(query) do
    require Ash.Query

    limit = Keyword.get(opts, :limit, 10)
    actor = Keyword.fetch!(opts, :actor)
    brain_ids = resolve_brain_ids(brain_id, actor)

    tsquery = build_tsquery(query)

    cond do
      brain_ids == [] ->
        []

      tsquery == "" ->
        []

      true ->
        # Raw Ecto query: lets us select the ts_rank_cd as a virtual field
        # AND sort by it in one go. Ash 3's ad-hoc-calc-then-sort-by-name
        # doesn't compose cleanly with an inline tsquery arg, and going
        # through the Page resource here adds no value (the policy gate
        # is the brain_id IN check above — brain_ids was already
        # actor-filtered by `resolve_brain_ids/2`).
        import Ecto.Query

        from(p in "brain_pages",
          where: p.brain_id in ^Enum.map(brain_ids, &Ecto.UUID.dump!/1),
          where: is_nil(p.deleted_at),
          where: fragment("search_vector @@ to_tsquery('english', ?)", ^tsquery),
          select: %{
            id: p.id,
            brain_id: p.brain_id,
            title: p.title,
            body: p.body,
            rank: fragment("ts_rank_cd(search_vector, to_tsquery('english', ?))", ^tsquery)
          },
          order_by: [
            desc: fragment("ts_rank_cd(search_vector, to_tsquery('english', ?))", ^tsquery)
          ],
          limit: ^limit
        )
        |> Magus.Repo.all()
        |> Enum.map(&raw_page_to_text_hit/1)
    end
  end

  defp raw_page_to_text_hit(row) do
    %{
      kind: :page,
      page_id: Ecto.UUID.load!(row.id),
      brain_id: Ecto.UUID.load!(row.brain_id),
      title: row.title,
      snippet: body_snippet(row.body),
      rank: row.rank
    }
  end

  @doc """
  Unified search across page chunks, source chunks, and file chunks
  (for files referenced from page bodies). Returns a flat list of hits
  sorted by score descending, capped at limit.

  Hit shape (all variants carry `:kind`, `:score`, `:brain_id`, `:snippet`):

    * `:page_chunk` — `:page_id`
    * `:source_chunk` — `:source_id`
    * `:file_chunk` — `:file_id`, `:page_id` (the page whose body links the file)
  """
  @spec search_with_files(String.t() | nil, [float()], keyword()) :: [map()]
  def search_with_files(brain_id, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    actor = Keyword.fetch!(opts, :actor)
    brain_ids = resolve_brain_ids(brain_id, actor)

    page_hits = run_page_chunk_search(brain_ids, query_embedding, limit, actor)
    source_hits = run_source_chunk_search(brain_ids, query_embedding, limit, actor)

    file_index = file_index_from_bodies(brain_ids, actor)
    file_ids = Map.keys(file_index)

    file_hits =
      if file_ids == [] or query_embedding == [] do
        []
      else
        run_file_chunk_search(file_ids, query_embedding, limit, file_index, actor)
      end

    (page_hits ++ source_hits ++ file_hits)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Saves a ProseMirror JSON document as the page body. Converts JSON → markdown,
  re-attaches the page's existing YAML frontmatter verbatim, then writes through
  the canonical `update_body` action (derived-state rebuild + optimistic lock).
  """
  def update_page_body_from_prosemirror(page, prosemirror_json, base_version, opts \\ []) do
    {fm, _rest} = Magus.Brain.ProseMirrorProfile.split_frontmatter(page.body || "")

    content_md =
      Magus.Markdown.ProseMirror.to_markdown(prosemirror_json,
        profile: Magus.Brain.ProseMirrorProfile
      )

    body = Magus.Brain.ProseMirrorProfile.reattach_frontmatter(fm, content_md)
    update_page_body(page, %{body: body, base_version: base_version}, opts)
  end

  # ----- internal helpers -----

  defp resolve_brain_ids(nil, actor), do: accessible_brain_ids(actor)
  defp resolve_brain_ids(brain_id, _actor) when is_binary(brain_id), do: [brain_id]

  defp accessible_brain_ids(actor) do
    require Ash.Query

    Magus.Brain.BrainResource
    |> Ash.Query.filter(is_archived == false)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp run_page_chunk_search([], _embedding, _limit, _actor), do: []
  defp run_page_chunk_search(_brain_ids, [], _limit, _actor), do: []

  # Raw Ecto on purpose: when AshPostgres uses `vector_distance` as BOTH a
  # loaded calc AND a sort key, it inlines the `^arg(:query_embedding)`
  # value into the SQL string as `ARRAY[float, float, ...]::vector` per
  # row, blowing the query past Postgres' work_mem on any meaningful
  # chunk count (real prod OOMs). The Pgvector struct below dumps to
  # the wire as a single binary parameter (`$N`), so the planner can
  # actually use the HNSW index instead of re-evaluating a 1536-element
  # array literal per row.
  #
  # Authorization is already done upstream: `resolve_brain_ids/2` filters
  # `brain_ids` to the actor's accessible set, so this raw query is safe
  # to run with `authorize?: false`-equivalent semantics.
  defp run_page_chunk_search(brain_ids, embedding, limit, _actor) do
    import Ecto.Query

    vector = Pgvector.new(embedding)
    brain_id_bins = brain_ids |> Enum.map(&Ecto.UUID.dump!/1)

    from(c in "brain_page_chunks",
      join: p in "brain_pages",
      on: p.id == c.page_id,
      where: not is_nil(c.embedding),
      where: p.brain_id in ^brain_id_bins,
      select: %{
        page_id: c.page_id,
        brain_id: p.brain_id,
        content: c.content,
        distance: fragment("? <=> ?", c.embedding, ^vector)
      },
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(fn row ->
      %{
        kind: :page_chunk,
        score: 1.0 - row.distance,
        brain_id: Ecto.UUID.load!(row.brain_id),
        page_id: Ecto.UUID.load!(row.page_id),
        snippet: row.content
      }
    end)
  end

  defp run_source_chunk_search([], _embedding, _limit, _actor), do: []
  defp run_source_chunk_search(_brain_ids, [], _limit, _actor), do: []

  defp run_source_chunk_search(brain_ids, embedding, limit, _actor) do
    import Ecto.Query

    vector = Pgvector.new(embedding)
    brain_id_bins = brain_ids |> Enum.map(&Ecto.UUID.dump!/1)

    from(c in "brain_source_chunks",
      join: s in "brain_sources",
      on: s.id == c.source_id,
      where: not is_nil(c.embedding),
      where: s.brain_id in ^brain_id_bins,
      select: %{
        source_id: c.source_id,
        brain_id: s.brain_id,
        content: c.content,
        distance: fragment("? <=> ?", c.embedding, ^vector)
      },
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(fn row ->
      %{
        kind: :source_chunk,
        score: 1.0 - row.distance,
        brain_id: Ecto.UUID.load!(row.brain_id),
        source_id: Ecto.UUID.load!(row.source_id),
        snippet: row.content
      }
    end)
  end

  defp run_file_chunk_search(file_ids, embedding, limit, file_index, _actor) do
    import Ecto.Query

    vector = Pgvector.new(embedding)
    file_id_bins = file_ids |> Enum.map(&Ecto.UUID.dump!/1)

    from(c in "file_chunks",
      where: not is_nil(c.embedding),
      where: c.file_id in ^file_id_bins,
      select: %{
        file_id: c.file_id,
        content: c.content,
        distance: fragment("? <=> ?", c.embedding, ^vector)
      },
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(fn row ->
      file_id = Ecto.UUID.load!(row.file_id)
      ref = Map.get(file_index, file_id) || %{}

      %{
        kind: :file_chunk,
        score: 1.0 - row.distance,
        brain_id: Map.get(ref, :brain_id),
        page_id: Map.get(ref, :page_id),
        file_id: file_id,
        snippet: row.content
      }
    end)
  end

  # Walks every non-trashed page in scope, parses `magus://file/<id>` and
  # `magus://image/<id>` references out of `page.body`, and returns
  # `%{file_id => %{page_id:, brain_id:}}` for the first page that mentions
  # each file. Authorized via the page read policy: pages the actor can't
  # see don't contribute.
  defp file_index_from_bodies([], _actor), do: %{}

  defp file_index_from_bodies(brain_ids, actor) do
    require Ash.Query

    Magus.Brain.Page
    |> Ash.Query.filter(brain_id in ^brain_ids and is_nil(deleted_at) and not is_nil(body))
    |> Ash.read!(actor: actor)
    |> Enum.reduce(%{}, fn page, acc ->
      page.body
      |> Magus.Brain.BodyParser.file_ids()
      |> Enum.reduce(acc, fn file_id, inner ->
        Map.put_new(inner, file_id, %{page_id: page.id, brain_id: page.brain_id})
      end)
    end)
  end

  defp build_tsquery(query) do
    query
    |> String.replace(~r/[^\w\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" & ")
  end

  # Builds a per-page hit with a short snippet drawn from the body.
  # The `:rank` field is the `ts_rank_cd` calc loaded by the caller.
  # Builds the runtime ts_rank_cd calculation for the supplied tsquery.
  # The tsquery is captured at definition time via the closure since the
  # `Ash.Expr.expr/1` macro needs the pin operator to resolve at compile.
  defp body_snippet(nil), do: ""

  defp body_snippet(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end
end
