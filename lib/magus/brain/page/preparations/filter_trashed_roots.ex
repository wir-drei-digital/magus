defmodule Magus.Brain.Page.Preparations.FilterTrashedRoots do
  @moduledoc """
  Restricts the `:trashed` read to "deletion roots" — pages that are
  themselves trashed AND whose ancestors are NOT trashed.

  Workspace scope: a nil `:workspace_id` argument means "brains
  without a workspace" (personal); a UUID means "brains in that
  workspace".
  """
  use Ash.Resource.Preparation

  require Ash.Query
  alias Magus.Brain.Page.Filters

  @impl true
  def prepare(query, _opts, _context) do
    workspace_id = Ash.Query.get_argument(query, :workspace_id)

    query
    |> Ash.Query.filter(not is_nil(deleted_at) and ^Filters.no_trashed_ancestor())
    |> apply_workspace_filter(workspace_id)
  end

  defp apply_workspace_filter(query, nil) do
    Ash.Query.filter(query, is_nil(brain.workspace_id))
  end

  defp apply_workspace_filter(query, workspace_id) do
    Ash.Query.filter(query, brain.workspace_id == ^workspace_id)
  end
end
