defmodule Magus.Agents.Tools.Brain.ReadBrain.Curation do
  @moduledoc """
  `ReadBrain` action handler for `list_curation_candidates`: a cheap,
  metadata-only maintenance scan of one brain for an automated curator.

  Extracted verbatim from `Magus.Agents.Tools.Brain.ReadBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged.
  """

  require Ash.Query

  alias Magus.Brain
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, tool_error: 3]
  import Magus.Agents.Tools.Brain.ReadBrain.Support, only: [blank?: 1]

  def handle_list_curation_candidates(params, ctx, context) do
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
    # `kind != :template` excludes reusable starting-point pages from every
    # curation signal below. Templates are parentless and unlinked by
    # construction (nothing wikilinks a template, and templates don't nest
    # under a parent), so without this filter they would wrongly surface as
    # both orphans and unfiled. `off_template_candidates/4` fetches template
    # BODIES separately via `Magus.Brain.templates_for_brain/2` (the diff
    # target, not a diff candidate), which is unaffected by this filter.
    page_query =
      Magus.Brain.Page
      |> Ash.Query.filter(brain_id == ^brain_id and kind != :template)
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

  # ATX section headings (`##` through `######`), text trimmed and downcased,
  # `#` markers stripped. Excludes level-1 (`# Title`): every template and
  # every page opens with its own `# <own title>` line, which never matches
  # across a template/instance pair by design (a page's title isn't the
  # template's title), so diffing it would flag every typed page as
  # off_template regardless of its actual sections. Level is otherwise
  # ignored for the diff (a template's `## Method` matches a page's
  # `### Method` just as well), and case is ignored too (a template's
  # `## Method` matches a page's `## method`), since the goal is "does the
  # section exist", not exact structural parity.
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
      [_, text] -> String.downcase(text)
      nil -> nil
    end
  end
end
