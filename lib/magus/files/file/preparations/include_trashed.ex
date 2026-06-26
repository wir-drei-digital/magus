defmodule Magus.Files.File.Preparations.IncludeTrashed do
  @moduledoc """
  Reset the query's filter to ignore the resource-level `base_filter`
  (`is_nil(deleted_at)`) and apply the trash-specific filter instead.

  Used by the `:list_trash` read action because base_filter and the action's
  `filter expr(...)` are AND'd at parse time: combining `is_nil(deleted_at)`
  with `not is_nil(deleted_at)` short-circuits to `false`. We can't express
  trash listing as a normal `filter`, so we install the filter from the
  preparation after dropping the inherited base filter from the query.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @spec prepare(Ash.Query.t(), map(), Ash.Resource.Preparation.context()) :: Ash.Query.t()
  def prepare(query, _opts, _ctx) do
    workspace_id = Ash.Query.get_argument(query, :workspace_id)
    actor_id = actor_id(query)

    query
    |> Map.put(:filter, nil)
    |> apply_trash_filter(actor_id, workspace_id)
  end

  defp actor_id(query) do
    case query.context do
      %{private: %{actor: %{id: id}}} -> id
      %{actor: %{id: id}} -> id
      _ -> nil
    end
  end

  defp apply_trash_filter(query, _actor_id, workspace_id) when not is_nil(workspace_id) do
    Ash.Query.filter(query, not is_nil(deleted_at) and workspace_id == ^workspace_id)
  end

  defp apply_trash_filter(query, actor_id, _workspace_id) when not is_nil(actor_id) do
    Ash.Query.filter(
      query,
      not is_nil(deleted_at) and user_id == ^actor_id and is_nil(workspace_id)
    )
  end

  defp apply_trash_filter(query, _actor_id, _workspace_id) do
    Ash.Query.filter(query, false)
  end
end
