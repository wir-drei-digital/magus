defmodule Magus.Brain.Hierarchy do
  @moduledoc """
  Shared helpers for ancestor/breadcrumb computation on brain pages.

  All functions work from an in-memory list of pages (no database queries),
  making them safe to call from both LiveView and tool contexts.
  """

  @doc """
  Builds a breadcrumb string like "Parent / Child / Page" from a page
  and a pre-loaded list of all pages in the brain.
  """
  def build_breadcrumb(page, all_pages) do
    pages_by_id = Map.new(all_pages, &{&1.id, &1})
    ancestors = collect_ancestors(page, pages_by_id, [])
    titles = Enum.map(ancestors, &(&1.title || "Untitled")) ++ [page.title || "Untitled"]
    Enum.join(titles, " / ")
  end

  @doc """
  Returns the list of ancestor pages (from root to immediate parent)
  using an in-memory map lookup. No database queries.
  """
  def ancestor_pages(page, all_pages) do
    pages_by_id = Map.new(all_pages, &{&1.id, &1})
    collect_ancestors(page, pages_by_id, [])
  end

  defp collect_ancestors(%{parent_page_id: nil}, _pages_by_id, acc), do: Enum.reverse(acc)

  defp collect_ancestors(%{parent_page_id: parent_id}, pages_by_id, acc) do
    case Map.get(pages_by_id, parent_id) do
      nil -> Enum.reverse(acc)
      parent -> collect_ancestors(parent, pages_by_id, [parent | acc])
    end
  end
end
