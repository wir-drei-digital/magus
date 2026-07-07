defmodule Magus.Agents.Tools.Brain.EditBrain.Structure do
  @moduledoc """
  `EditBrain` action handlers for brain/page STRUCTURE: `create_brain`,
  `rename_page`, `move_page`, and `delete_page`.

  Extracted verbatim from `Magus.Agents.Tools.Brain.EditBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged. Each
  `handle_*/N` function is called directly from the tool's `dispatch/4`
  and returns the same `{:ok, map()}` shape the inline clause used to.
  """

  alias Magus.Brain
  alias Magus.Agents.Tools.Brain.EditBrain.Support

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, tool_error: 3]

  import Support, only: [build_current: 2, load_brain: 2, blank?: 1]

  # ---------------------------------------------------------------------------
  # create_brain (unchanged behavior)
  # ---------------------------------------------------------------------------

  def handle_create_brain(params, ctx, context) do
    title = get_param(params, :title)

    if blank?(title) do
      {:ok, %{error: "Missing required parameter: title"}}
    else
      attrs = %{title: title}

      attrs =
        if d = get_param(params, :description), do: Map.put(attrs, :description, d), else: attrs

      attrs = if i = get_param(params, :icon), do: Map.put(attrs, :icon, i), else: attrs

      attrs =
        case Map.get(context, :workspace_id) do
          nil -> attrs
          ws_id -> Map.put(attrs, :workspace_id, ws_id)
        end

      case Brain.create_brain(attrs, actor: ctx.user) do
        {:ok, brain} ->
          Magus.FeatureUsage.track(ctx.user_id, "brains", "create")

          {:ok,
           %{
             action: "create_brain",
             brain_id: brain.id,
             brain_title: brain.title,
             current: build_current(brain, nil),
             hint: "Brain '#{brain.title}' created. Use write_page to add the first page."
           }}

        {:error, err} ->
          {:ok,
           %{
             error:
               tool_error(
                 "create brain",
                 err,
                 "Check the title is non-empty and the actor has permission."
               )
           }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # rename_page / move_page / delete_page (preserved)
  # ---------------------------------------------------------------------------

  def handle_rename_page(params, ctx) do
    page_id = get_param(params, :page_id)
    title = get_param(params, :title)

    cond do
      is_nil(page_id) ->
        {:ok, %{error: "Missing required parameter: page_id"}}

      blank?(title) ->
        {:ok, %{error: "Missing required parameter: title"}}

      true ->
        with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
             {:ok, updated} <- Brain.update_page_title(page, %{title: title}, actor: ctx.user) do
          brain = load_brain(updated, ctx)

          {:ok,
           %{
             action: "rename_page",
             page_id: updated.id,
             page_title: updated.title,
             current: build_current(brain, updated),
             hint: "Renamed to '#{updated.title}'."
           }}
        else
          {:error, err} ->
            {:ok,
             %{
               error: tool_error("rename page", err, "Verify page_id with read_brain list_pages.")
             }}
        end
    end
  end

  def handle_delete_page(params, ctx) do
    page_id = get_param(params, :page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
           descendant_count = count_descendants(page_id, ctx),
           {:ok, _trashed} <- Brain.soft_delete_page(page, actor: ctx.user) do
        hint =
          if descendant_count > 0 do
            "Moved page and #{descendant_count} sub-page(s) to trash. The user can restore within 30 days."
          else
            "Moved page to trash. The user can restore within 30 days."
          end

        {:ok, %{action: "delete_page", page_id: page_id, hint: hint}}
      else
        {:error, err} ->
          {:ok,
           %{
             error: tool_error("delete page", err, "Verify page_id with read_brain list_pages.")
           }}
      end
    end
  end

  def handle_move_page(params, ctx) do
    page_id = get_param(params, :page_id)
    parent_page_id = get_param(params, :parent_page_id)

    if is_nil(page_id) do
      {:ok, %{error: "Missing required parameter: page_id"}}
    else
      with {:ok, page} <- Brain.get_page(page_id, actor: ctx.user),
           {:ok, moved} <-
             Brain.move_page_to_parent(page, %{parent_page_id: parent_page_id}, actor: ctx.user) do
        {:ok, reloaded} = Brain.get_page(moved.id, actor: ctx.user)
        brain = load_brain(reloaded, ctx)

        {:ok,
         %{
           action: "move_page",
           page_id: reloaded.id,
           parent_page_id: reloaded.parent_page_id,
           depth: reloaded.depth,
           current: build_current(brain, reloaded),
           hint: "Page moved."
         }}
      else
        {:error, err} ->
          {:ok,
           %{
             error:
               tool_error(
                 "move page",
                 err,
                 "Verify page_id and parent_page_id (pass null for root)."
               )
           }}
      end
    end
  end

  defp count_descendants(page_id, ctx) do
    case Brain.list_children_pages(page_id, actor: ctx.user) do
      {:ok, children} ->
        length(children) +
          Enum.sum(Enum.map(children, fn c -> count_descendants(c.id, ctx) end))

      _ ->
        0
    end
  end
end
