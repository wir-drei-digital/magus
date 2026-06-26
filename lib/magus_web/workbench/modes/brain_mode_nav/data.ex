defmodule MagusWeb.Workbench.Modes.BrainModeNav.Data do
  @moduledoc """
  Data shaper for the workbench Brain mode nav. Returns
  `[%Section{}]` ready to feed into `ResourceTree`.

  Brains are rendered as folder nodes; pages are loaded lazily when
  a brain is expanded.
  """

  alias MagusWeb.Workbench.Layout.ResourceTree.{Section, Node, Action}

  def load_sections(opts) do
    user = Map.fetch!(opts, :user)
    workspace_id = Map.get(opts, :workspace_id)
    search = String.downcase(Map.get(opts, :search_query) || "")
    expanded_brain_ids = Map.get(opts, :expanded_brain_ids) || MapSet.new()
    target = Map.fetch!(opts, :tree_target)
    filter = Map.get(opts, :nav_filter, :all)

    if workspace_id do
      {show_shared?, show_personal?} = visible_sections(filter)
      shared = if show_shared?, do: list_brains(:shared, workspace_id, user), else: []
      personal = if show_personal?, do: list_brains(:personal_in_ws, workspace_id, user), else: []

      Enum.reject(
        [
          show_shared? &&
            section(:shared, "Shared", shared, expanded_brain_ids, target, search, user),
          show_personal? &&
            section(:personal, "Personal", personal, expanded_brain_ids, target, search, user)
        ],
        &(&1 == false)
      )
    else
      personal = list_brains(:personal, nil, user)
      [section(:personal, nil, personal, expanded_brain_ids, target, search, user)]
    end
  end

  defp visible_sections(:all), do: {true, true}
  defp visible_sections(:shared), do: {true, false}
  defp visible_sections(:personal), do: {false, true}

  defp list_brains(:shared, workspace_id, user) do
    Magus.Brain.list_brains_for_workspace!(workspace_id, actor: user)
    |> Enum.filter(&Map.get(&1, :is_shared_to_workspace, false))
  rescue
    _ -> []
  end

  defp list_brains(:personal_in_ws, workspace_id, user) do
    Magus.Brain.list_brains_for_workspace!(workspace_id, actor: user)
    |> Enum.reject(&Map.get(&1, :is_shared_to_workspace, false))
  rescue
    _ -> []
  end

  defp list_brains(:personal, _ws, user) do
    Magus.Brain.personal_brains!(actor: user)
  end

  defp section(key, label, brains, expanded_ids, target, search, user) do
    nodes =
      brains
      |> filter_by_search(search)
      |> Enum.map(&brain_to_node(&1, expanded_ids, target, user))

    %Section{
      key: key,
      label: label,
      nodes: nodes,
      empty_message: empty_msg(key),
      target: target
    }
  end

  defp brain_to_node(brain, expanded_ids, target, user) do
    %{folders: folder_pages, leaves: leaf_pages} =
      if MapSet.member?(expanded_ids, brain.id) do
        load_page_tree(brain, target, user)
      else
        %{folders: [], leaves: []}
      end

    Node.new_folder(
      id: brain.id,
      label: brain.title || "Untitled brain",
      icon: "lucide-brain",
      resource_type: :brain,
      children: folder_pages,
      conversations: leaf_pages,
      actions: brain_actions(brain, target),
      click_event: %{event: "toggle_folder", values: %{"folder-id" => brain.id}, target: target},
      create_child_event: %{
        event: "create_brain_page",
        values: %{"brain-id" => brain.id},
        target: nil,
        label: "New page",
        icon: "lucide-plus"
      }
    )
  end

  # Personal brains (no workspace_id) can't be shared; show edit only.
  # Workspace-scoped brains get an inline share/unshare toggle alongside
  # the edit pencil so the user doesn't have to open each brain to flip
  # visibility.
  defp brain_actions(%{workspace_id: nil}, target), do: [edit_action(target, nil)]

  defp brain_actions(brain, target) do
    share = brain.is_shared_to_workspace

    [
      Action.new(
        icon: if(share, do: "lucide-user-check", else: "lucide-users"),
        event: if(share, do: "unshare_brain", else: "share_brain"),
        values: %{"brain-id" => brain.id},
        target: target,
        title: if(share, do: "Stop sharing with workspace", else: "Share with workspace")
      ),
      edit_action(target, brain.id)
    ]
  end

  defp edit_action(target, brain_id) do
    Action.new(
      icon: "lucide-pencil",
      event: "edit_brain",
      values: %{"brain-id" => brain_id},
      target: target,
      title: "Edit brain"
    )
  end

  # Loads every page of the brain in one query and builds a recursive tree
  # of `%Node{}`s. Pages with children render as folders (so the existing
  # `folder_node` recursion handles arbitrary depth, up to the schema's
  # depth-2 cap); pages without children render as leaves. Returned shape
  # is `%{folders: [..folder nodes..], leaves: [..leaf nodes..]}` because
  # `folder_node` keeps sub-folders and leaves in two separate slots
  # (`children` and `conversations`).
  defp load_page_tree(brain, target, user) do
    case Magus.Brain.list_pages(brain.id, actor: user) do
      {:ok, all_pages} ->
        by_parent = Enum.group_by(all_pages, & &1.parent_page_id)

        by_parent
        |> Map.get(nil, [])
        |> Enum.sort_by(& &1.position)
        |> Enum.map(&page_to_tree_node(&1, by_parent, target))
        |> partition_nodes()

      _ ->
        %{folders: [], leaves: []}
    end
  rescue
    _ -> %{folders: [], leaves: []}
  end

  defp page_to_tree_node(page, by_parent, target) do
    children =
      by_parent
      |> Map.get(page.id, [])
      |> Enum.sort_by(& &1.position)

    case children do
      [] ->
        page_to_leaf(page, target)

      list ->
        child_nodes = Enum.map(list, &page_to_tree_node(&1, by_parent, target))
        %{folders: subfolders, leaves: subleaves} = partition_nodes(child_nodes)
        page_to_folder(page, subfolders, subleaves, target)
    end
  end

  defp partition_nodes(nodes) do
    {folders, leaves} = Enum.split_with(nodes, &(&1.kind == :folder))
    %{folders: folders, leaves: leaves}
  end

  defp page_to_leaf(page, target) do
    Node.new_leaf(
      id: page.id,
      label: page.title || "Untitled page",
      icon: "lucide-file-text",
      resource_type: :brain_page,
      # Reserve the chevron-width gutter so leaf pages align with sibling
      # pages-with-subpages (which carry a chevron) and indent one clear
      # level below their parent. See Node docs.
      gutter: true,
      actions: [page_trash_action(page, target)],
      click_event: page_open_event(page)
    )
  end

  # Pages with children render as folders so the tree recurses, but the
  # row click should OPEN the page (like a leaf), not toggle. A separate
  # chevron on the left handles expand/collapse — that affordance is
  # specific to pages-with-sub-pages; brain folders keep the simpler
  # whole-row-toggles UX.
  defp page_to_folder(page, subfolders, subleaves, target) do
    Node.new_folder(
      id: page.id,
      label: page.title || "Untitled page",
      icon: "lucide-file-text",
      resource_type: :brain_page,
      children: subfolders,
      conversations: subleaves,
      actions: [page_trash_action(page, target)],
      click_event: page_open_event(page),
      chevron_event: %{
        event: "toggle_folder",
        values: %{"folder-id" => page.id},
        target: target
      }
    )
  end

  defp page_trash_action(page, target) do
    Action.new(
      icon: "lucide-trash-2",
      event: "trash_page",
      values: %{"page-id" => page.id},
      target: target,
      title: "Move to trash",
      style: :danger,
      confirm: "Move this page (and any sub-pages) to the trash?"
    )
  end

  defp page_open_event(page) do
    %{
      event: "open_tab",
      values: %{
        "type" => "brain_page",
        "id" => page.id,
        "label" => page.title || "Untitled page"
      },
      target: nil
    }
  end

  defp filter_by_search(items, ""), do: items

  defp filter_by_search(items, search) do
    Enum.filter(items, fn b ->
      String.contains?(String.downcase(b.title || ""), search)
    end)
  end

  defp empty_msg(:shared), do: "No shared brains"
  defp empty_msg(:personal), do: "No brains yet"
  defp empty_msg(_), do: nil
end
