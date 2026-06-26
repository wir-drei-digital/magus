defmodule Magus.Brain.Page.Filters do
  @moduledoc """
  Shared Ash filter expressions for `Magus.Brain.Page`.

  The soft-delete model is "stamp only the root": when a user trashes a
  page we set its `:deleted_at` and leave descendants untouched. A page
  is visible iff its own `:deleted_at` is NULL AND no ancestor in its
  parent chain has `:deleted_at` set. The 30-day cleanup cron hard
  destroys the root, and Postgres' `on_delete: :delete` FK cascades to
  the descendants — no Ash-side recursion is needed at write time.

  The filter is a recursive CTE because:
    1. `parent_page.deleted_at` would force an INNER JOIN through the
       relationship's primary `:read` action — which itself filters
       trashed rows — making trashed ancestors invisible.
    2. CTE is depth-agnostic — page hierarchy depth is unbounded as
       of Phase C7, and this filter walks the chain regardless.
  """

  import Ash.Expr

  @doc """
  Returns an Ash filter expression that evaluates to TRUE when no
  ancestor of the current row is trashed. Splice into other filters
  with `^`:

      filter expr(brain_id == ^arg(:brain_id) and ^Filters.no_trashed_ancestor())
  """
  def no_trashed_ancestor do
    expr(
      fragment(
        """
        (? IS NULL OR NOT EXISTS (
          WITH RECURSIVE anc(id, parent_page_id, deleted_at) AS (
            SELECT id, parent_page_id, deleted_at
            FROM brain_pages WHERE id = ?
            UNION ALL
            SELECT p.id, p.parent_page_id, p.deleted_at
            FROM brain_pages p INNER JOIN anc a ON p.id = a.parent_page_id
          )
          SELECT 1 FROM anc WHERE deleted_at IS NOT NULL
        ))
        """,
        parent_page_id,
        parent_page_id
      )
    )
  end
end
