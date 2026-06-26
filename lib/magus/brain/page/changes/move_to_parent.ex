defmodule Magus.Brain.Page.Changes.MoveToParent do
  @moduledoc """
  Moves a page to a new parent (or to root).

  Validates that the move is not a self-reference and not under one
  of the page's own descendants. Updates the page's depth and
  cascades the depth delta down its subtree. The old maximum-nesting
  rejection was removed in Phase C7; depth is still tracked for
  breadcrumbs and sort order.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      page_id = changeset.data.id
      new_parent_id = Ash.Changeset.get_attribute(changeset, :parent_page_id)

      with :ok <- validate_not_self(page_id, new_parent_id),
           {:ok, new_depth} <- resolve_new_depth(new_parent_id),
           :ok <- validate_not_descendant(page_id, new_parent_id) do
        depth_delta = new_depth - changeset.data.depth

        changeset = Ash.Changeset.force_change_attribute(changeset, :depth, new_depth)

        Ash.Changeset.after_action(changeset, fn _changeset, page ->
          update_descendant_depths(page_id, depth_delta)
          reposition_in_new_parent(page, new_parent_id)
          {:ok, page}
        end)
      else
        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :parent_page_id, message: message)
      end
    end)
  end

  defp validate_not_self(page_id, parent_id) do
    if page_id == parent_id, do: {:error, "a page cannot be its own parent"}, else: :ok
  end

  defp resolve_new_depth(nil), do: {:ok, 0}

  defp resolve_new_depth(parent_id) do
    case Ash.get(Magus.Brain.Page, parent_id, authorize?: false) do
      {:ok, parent} -> {:ok, parent.depth + 1}
      {:error, _} -> {:error, "parent page not found"}
    end
  end

  defp validate_not_descendant(_page_id, nil), do: :ok

  defp validate_not_descendant(page_id, target_parent_id) do
    if is_descendant?(target_parent_id, page_id) do
      {:error, "cannot move a page under one of its own descendants"}
    else
      :ok
    end
  end

  defp is_descendant?(candidate_id, ancestor_id) do
    case Ash.get(Magus.Brain.Page, candidate_id, authorize?: false) do
      {:ok, %{parent_page_id: nil}} -> false
      {:ok, %{parent_page_id: ^ancestor_id}} -> true
      {:ok, %{parent_page_id: next_id}} -> is_descendant?(next_id, ancestor_id)
      _ -> false
    end
  end

  defp update_descendant_depths(_page_id, 0), do: :ok

  defp update_descendant_depths(page_id, depth_delta) do
    children =
      Magus.Brain.Page
      |> Ash.Query.filter(parent_page_id == ^page_id)
      |> Ash.read!(authorize?: false)

    Enum.each(children, fn child ->
      new_depth = child.depth + depth_delta
      Ash.update!(child, %{depth: new_depth}, action: :reposition, authorize?: false)
      update_descendant_depths(child.id, depth_delta)
    end)
  end

  defp reposition_in_new_parent(page, new_parent_id) do
    brain_id = page.brain_id

    siblings =
      if is_nil(new_parent_id) do
        Magus.Brain.Page
        |> Ash.Query.filter(brain_id == ^brain_id and is_nil(parent_page_id) and id != ^page.id)
        |> Ash.Query.sort(position: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
      else
        Magus.Brain.Page
        |> Ash.Query.filter(
          brain_id == ^brain_id and parent_page_id == ^new_parent_id and id != ^page.id
        )
        |> Ash.Query.sort(position: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
      end

    new_position =
      case siblings do
        [last] -> last.position + 1.0
        [] -> 1.0
      end

    Ash.update!(page, %{position: new_position}, action: :reposition, authorize?: false)
  end
end
