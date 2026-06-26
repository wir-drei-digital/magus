defmodule Magus.Brain.Page.Changes.ClearDeleted do
  @moduledoc """
  Clears `:deleted_at` on a single page. Refuses to run when:

    * the page is not currently trashed (`:deleted_at` is nil), or
    * any ancestor of the page is itself trashed.

  Refusing the second case prevents an orphan: a visible page whose
  parent is still in the trash and therefore hidden from every read.
  The user must restore the deepest trashed ancestor first.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      page = cs.data

      cond do
        is_nil(page.deleted_at) ->
          Ash.Changeset.add_error(cs, field: :deleted_at, message: "page is not in the trash")

        ancestor_still_trashed?(page) ->
          Ash.Changeset.add_error(cs,
            field: :parent_page_id,
            message: "restore the parent page first"
          )

        true ->
          Ash.Changeset.force_change_attribute(cs, :deleted_at, nil)
      end
    end)
  end

  defp ancestor_still_trashed?(%{parent_page_id: nil}), do: false

  defp ancestor_still_trashed?(%{parent_page_id: parent_id}) do
    walk(parent_id)
  end

  defp walk(nil), do: false

  defp walk(page_id) do
    case Magus.Brain.Page
         |> Ash.Query.for_read(:read_including_trashed)
         |> Ash.Query.filter(id == ^page_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> false
      {:ok, %{deleted_at: nil} = page} -> walk(page.parent_page_id)
      {:ok, %{deleted_at: _stamp}} -> true
      {:error, _} -> false
    end
  end
end
