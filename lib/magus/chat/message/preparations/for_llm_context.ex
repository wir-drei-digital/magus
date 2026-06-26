defmodule Magus.Chat.Message.Preparations.ForLlmContext do
  @moduledoc """
  Prepares the query for the :for_llm_context action.

  Applies optional filters:
  - `exclude_id` - Excludes a specific message (typically the current message)
  - `cutoff_at` - Upper bound: only messages with `inserted_at <= cutoff_at`
  - `since_at` - Lower bound: only messages with `inserted_at >= since_at`
  - `recent_limit` - Returns only the N most recent messages
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> maybe_exclude_id()
    |> maybe_cutoff_at()
    |> maybe_since_at()
    |> maybe_recent_limit()
  end

  defp maybe_exclude_id(query) do
    case Ash.Query.get_argument(query, :exclude_id) do
      nil -> query
      exclude_id -> Ash.Query.filter(query, id != ^exclude_id)
    end
  end

  defp maybe_cutoff_at(query) do
    case Ash.Query.get_argument(query, :cutoff_at) do
      nil -> query
      cutoff -> Ash.Query.filter(query, inserted_at <= ^cutoff)
    end
  end

  defp maybe_since_at(query) do
    case Ash.Query.get_argument(query, :since_at) do
      nil -> query
      since -> Ash.Query.filter(query, inserted_at >= ^since)
    end
  end

  defp maybe_recent_limit(query) do
    case Ash.Query.get_argument(query, :recent_limit) do
      nil ->
        query

      limit when is_integer(limit) and limit > 0 ->
        # Sort descending + limit to get the N most recent rows at the DB level.
        # The caller (BuildMessageHistory) reverses back to ascending order.
        query
        |> Ash.Query.unset(:sort)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.Query.limit(limit)

      _ ->
        query
    end
  end
end
