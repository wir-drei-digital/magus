defmodule Magus.Files.File.Preparations.ApplyBrowserFilters do
  @moduledoc """
  Applies the browser-only filter arguments (`browser_type`, `browser_modified`,
  `browser_source`) to a query. Each argument is optional; nil/`"any"` is a
  no-op.

  The argument names are namespaced (`browser_*`) so they don't collide with
  the resource's own column names like `source` and `type`.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @spec prepare(Ash.Query.t(), map(), Ash.Resource.Preparation.context()) :: Ash.Query.t()
  def prepare(query, _opts, _ctx) do
    query
    |> apply_type(Ash.Query.get_argument(query, :browser_type))
    |> apply_modified(Ash.Query.get_argument(query, :browser_modified))
    |> apply_source(Ash.Query.get_argument(query, :browser_source))
  end

  defp apply_type(q, nil), do: q
  defp apply_type(q, ""), do: q
  defp apply_type(q, "any"), do: q
  defp apply_type(q, "image"), do: Ash.Query.filter(q, type == :image)
  defp apply_type(q, "video"), do: Ash.Query.filter(q, type == :video)

  defp apply_type(q, "pdf"),
    do: Ash.Query.filter(q, mime_type == "application/pdf")

  defp apply_type(q, "document"),
    do: Ash.Query.filter(q, type == :document and mime_type != "application/pdf")

  defp apply_type(q, "text"), do: Ash.Query.filter(q, type == :text)
  defp apply_type(q, "email"), do: Ash.Query.filter(q, type == :email)
  defp apply_type(q, _), do: q

  defp apply_modified(q, nil), do: q
  defp apply_modified(q, ""), do: q
  defp apply_modified(q, "any"), do: q
  defp apply_modified(q, "any_time"), do: q

  defp apply_modified(q, bucket) do
    case modified_cutoff(bucket) do
      nil -> q
      {:since, dt} -> Ash.Query.filter(q, updated_at >= ^dt)
      {:before, dt} -> Ash.Query.filter(q, updated_at < ^dt)
    end
  end

  defp modified_cutoff("today"),
    do: {:since, DateTime.add(DateTime.utc_now(), -1, :day)}

  defp modified_cutoff("this_week"),
    do: {:since, DateTime.add(DateTime.utc_now(), -7, :day)}

  defp modified_cutoff("this_month"),
    do: {:since, DateTime.add(DateTime.utc_now(), -30, :day)}

  defp modified_cutoff("this_year"),
    do: {:since, DateTime.add(DateTime.utc_now(), -365, :day)}

  defp modified_cutoff("older"),
    do: {:before, DateTime.add(DateTime.utc_now(), -365, :day)}

  defp modified_cutoff(_), do: nil

  defp apply_source(q, nil), do: q
  defp apply_source(q, ""), do: q
  defp apply_source(q, "any"), do: q
  defp apply_source(q, "uploaded"), do: Ash.Query.filter(q, source == :user)
  defp apply_source(q, "agent"), do: Ash.Query.filter(q, source == :agent)
  defp apply_source(q, "synced"), do: Ash.Query.filter(q, source == :connector)
  defp apply_source(q, _), do: q
end
