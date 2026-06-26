defmodule MagusWeb.Workbench.Modes.ChatModeNav.Data do
  @moduledoc """
  Pure data loader/shaper for the workbench chat mode tree.

  Given a user, optional workspace, search query, and the persisted
  expanded-folders map, returns a `%TreeData{}` ready for rendering.

  The `expanded_folders` opt is reserved for the LiveComponent's render-time
  overlay logic; the loader does not currently consume it.
  """

  alias Magus.Chat
  alias MagusWeb.ChatLive.Helpers, as: ChatHelpers
  alias MagusWeb.Workbench.Layout.ResourceTree.{Action, Node, Section}

  defmodule TreeData do
    @moduledoc """
    Render-ready chat-mode navigation tree.
    """

    defstruct in_workspace?: false,
              favorites: [],
              favorited_ids: MapSet.new(),
              shared_folders: [],
              shared_unfiled: [],
              personal_folders: [],
              personal_unfiled_by_date: [],
              threads_by_conversation: %{},
              auto_expanded_ids: MapSet.new()

    @type t :: %__MODULE__{
            in_workspace?: boolean(),
            favorites: list(map()),
            favorited_ids: MapSet.t(),
            shared_folders: list(map()),
            shared_unfiled: list(map()),
            personal_folders: list(map()),
            personal_unfiled_by_date: list({String.t(), list(map())}),
            threads_by_conversation: %{optional(binary()) => list(map())},
            auto_expanded_ids: MapSet.t()
          }
  end

  @type opts :: %{
          required(:user) => map(),
          required(:workspace_id) => binary() | nil,
          required(:search_query) => binary(),
          required(:expanded_folders) => %{binary() => boolean()}
        }

  @spec load_tree(opts()) :: TreeData.t()
  def load_tree(opts) do
    user = Map.fetch!(opts, :user)
    workspace_id = Map.get(opts, :workspace_id)
    search = String.downcase(Map.get(opts, :search_query) || "")
    expanded_folders = Map.get(opts, :expanded_folders) || %{}

    if workspace_id do
      load_workspace_tree(user, workspace_id, search, expanded_folders)
    else
      load_personal_tree(user, search, expanded_folders)
    end
  end

  defp load_personal_tree(user, search, _expanded) do
    folders = Chat.my_folders!(%{kinds: [:conversations, :mixed]}, actor: user)
    # Filed conversations populate the folder tree (uncapped — a folder always
    # shows all of its conversations). The flat unfiled list is the capped
    # quick-access list (`:unfiled_conversations`, limit @unfiled_conversations_limit),
    # ordered by most recent message. The full archive lives in the history view.
    filed = Chat.filed_conversations!(actor: user)
    unfiled = Chat.unfiled_conversations!(actor: user)
    favorites = Chat.personal_favorite_conversations!(actor: user)

    # Favorites render in their own section, so drop them from both lists.
    favorited_ids = MapSet.new(favorites, & &1.id)
    filed = Enum.reject(filed, &MapSet.member?(favorited_ids, &1.id))
    unfiled = Enum.reject(unfiled, &MapSet.member?(favorited_ids, &1.id))

    filtered_filed = filter_by_search(filed, search)
    filtered_unfiled = filter_by_search(unfiled, search)
    {filtered_folders, auto_ids} = filter_folders(folders, filed, search)

    folder_tree = build_tree(filtered_folders, filtered_filed)

    threads = load_threads(filtered_filed ++ filtered_unfiled ++ favorites, user)

    %TreeData{
      in_workspace?: false,
      favorites: filter_by_search(favorites, search),
      favorited_ids: favorited_ids,
      personal_folders: folder_tree,
      personal_unfiled_by_date: ChatHelpers.group_conversations_by_date(filtered_unfiled),
      threads_by_conversation: threads,
      auto_expanded_ids: auto_ids
    }
  end

  defp load_workspace_tree(user, workspace_id, search, _expanded) do
    require Ash.Query

    folders =
      Magus.Chat.Folder
      |> Ash.Query.for_read(:workspace_folders, %{
        workspace_id: workspace_id,
        kinds: [:conversations, :mixed]
      })
      |> Ash.Query.load(:is_shared_to_workspace)
      |> Ash.read!(actor: user)

    conversations = Chat.workspace_conversations!(workspace_id, actor: user)
    favorites = Chat.workspace_favorite_conversations!(workspace_id, actor: user)

    favorited_ids = MapSet.new(favorites, & &1.id)
    conversations = Enum.reject(conversations, &MapSet.member?(favorited_ids, &1.id))

    filtered_convs = filter_by_search(conversations, search)
    filtered_folders = filter_by_search_folder(folders, conversations, search)

    {shared_folders, personal_folders} =
      Enum.split_with(filtered_folders, & &1.is_shared_to_workspace)

    {shared_convs, personal_convs} =
      Enum.split_with(filtered_convs, & &1.is_shared_to_workspace)

    {filed_shared, unfiled_shared} = Enum.split_with(shared_convs, &(&1.folder_id != nil))
    {filed_personal, unfiled_personal} = Enum.split_with(personal_convs, &(&1.folder_id != nil))

    shared_tree = build_tree(shared_folders, filed_shared)
    personal_tree = build_tree(personal_folders, filed_personal)

    threads = load_threads(filtered_convs ++ favorites, user)

    auto_expanded =
      if search == "" do
        MapSet.new()
      else
        shared_auto = expanded_ancestors(shared_folders, folders)
        personal_auto = expanded_ancestors(personal_folders, folders)
        MapSet.union(shared_auto, personal_auto)
      end

    %TreeData{
      in_workspace?: true,
      favorites: filter_by_search(favorites, search),
      favorited_ids: favorited_ids,
      shared_folders: shared_tree,
      shared_unfiled: unfiled_shared,
      personal_folders: personal_tree,
      personal_unfiled_by_date: ChatHelpers.group_conversations_by_date(unfiled_personal),
      threads_by_conversation: threads,
      auto_expanded_ids: auto_expanded
    }
  end

  defp filter_by_search(items, ""), do: items

  defp filter_by_search(items, search) do
    Enum.filter(items, fn c ->
      String.contains?(String.downcase(c.title || ""), search)
    end)
  end

  # Returns ALL folders unchanged (no pruning); only the auto-expand set is computed.
  defp filter_folders(folders, _all_convs, ""), do: {folders, MapSet.new()}

  defp filter_folders(folders, all_convs, search) do
    convs_by_folder = Enum.group_by(all_convs, & &1.folder_id)

    matching_ids =
      folders
      |> Enum.filter(fn f ->
        String.contains?(String.downcase(f.name || ""), search) or
          Enum.any?(Map.get(convs_by_folder, f.id, []), fn c ->
            String.contains?(String.downcase(c.title || ""), search)
          end)
      end)
      |> Enum.map(& &1.id)

    by_id = Map.new(folders, &{&1.id, &1})

    expanded_with_ancestors =
      matching_ids
      |> Enum.flat_map(&ancestor_chain(&1, by_id))
      |> MapSet.new()

    {folders, expanded_with_ancestors}
  end

  defp filter_by_search_folder(folders, _all_convs, ""), do: folders

  defp filter_by_search_folder(folders, all_convs, search) do
    convs_by_folder = Enum.group_by(all_convs, & &1.folder_id)

    Enum.filter(folders, fn f ->
      String.contains?(String.downcase(f.name || ""), search) or
        Enum.any?(Map.get(convs_by_folder, f.id, []), fn c ->
          String.contains?(String.downcase(c.title || ""), search)
        end)
    end)
  end

  defp expanded_ancestors(filtered, all_folders) do
    by_id = Map.new(all_folders, &{&1.id, &1})

    filtered
    |> Enum.flat_map(&ancestor_chain(&1.id, by_id))
    |> MapSet.new()
  end

  defp ancestor_chain(folder_id, %{} = by_id) do
    Stream.unfold(folder_id, fn
      nil ->
        nil

      id ->
        case Map.get(by_id, id) do
          nil -> nil
          folder -> {id, folder.parent_id}
        end
    end)
    |> Enum.to_list()
  end

  defp build_tree(folders, conversations) do
    convs_by_folder = Enum.group_by(conversations, & &1.folder_id)
    by_parent = Enum.group_by(folders, & &1.parent_id)
    build_children(by_parent, convs_by_folder, nil)
  end

  defp build_children(by_parent, convs_by_folder, parent_id) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.sort_by(&String.downcase(&1.name || ""))
    |> Enum.map(fn folder ->
      children = build_children(by_parent, convs_by_folder, folder.id)
      conversations = Map.get(convs_by_folder, folder.id, [])
      Map.merge(folder, %{children: children, conversations: conversations})
    end)
  end

  defp load_threads(convs, user) do
    ChatHelpers.load_threads_for_sidebar(convs, user)
  end

  @doc """
  Convert a `%TreeData{}` into a list of `%Section{}` for the
  ResourceTree component.

  Opts:
  - `:nav_filter` — `:all | :shared | :personal` (workspace mode).
  - `:editing_folder_id` — for inline rename.
  - `:favorites_collapsed?` — collapse state for the favorites section.
  - `:tree_target` — `phx-target` value for events emitted by the tree.
  """
  def to_sections(%TreeData{} = tree, opts) do
    nav_filter = Keyword.get(opts, :nav_filter, :all)
    editing_folder_id = Keyword.get(opts, :editing_folder_id)
    favorites_collapsed? = Keyword.get(opts, :favorites_collapsed?, false)
    target = Keyword.fetch!(opts, :tree_target)
    in_workspace? = tree.in_workspace?

    ctx = %{
      target: target,
      in_workspace?: in_workspace?,
      favorited_ids: tree.favorited_ids || MapSet.new()
    }

    []
    |> maybe_add_favorites(tree, favorites_collapsed?, ctx)
    |> maybe_add_shared(tree, nav_filter, editing_folder_id, ctx)
    |> maybe_add_personal(tree, nav_filter, editing_folder_id, ctx)
  end

  defp maybe_add_favorites(sections, %TreeData{favorites: []}, _collapsed?, _ctx),
    do: sections

  defp maybe_add_favorites(
         sections,
         %TreeData{favorites: favs} = tree,
         collapsed?,
         ctx
       ) do
    nodes =
      Enum.map(favs, fn conv ->
        conversation_to_leaf(conv, "personal", tree.threads_by_conversation, ctx)
      end)

    section = %Section{
      key: :favorites,
      label: "Favorites (#{length(favs)})",
      nodes: nodes,
      collapsible?: true,
      collapsed?: collapsed?,
      on_toggle: "toggle_favorites_collapsed",
      target: ctx.target,
      empty_message: nil
    }

    sections ++ [section]
  end

  defp maybe_add_shared(sections, %TreeData{in_workspace?: false}, _filter, _eid, _ctx),
    do: sections

  defp maybe_add_shared(sections, _tree, filter, _eid, _ctx)
       when filter not in [:all, :shared],
       do: sections

  defp maybe_add_shared(sections, %TreeData{} = tree, _filter, editing_folder_id, ctx) do
    folder_nodes =
      Enum.map(tree.shared_folders, fn folder ->
        folder_to_node(
          folder,
          "shared",
          tree.threads_by_conversation,
          true,
          editing_folder_id,
          ctx
        )
      end)

    unfiled_nodes =
      Enum.map(tree.shared_unfiled, fn conv ->
        conversation_to_leaf(conv, "shared", tree.threads_by_conversation, %{
          ctx
          | in_workspace?: true
        })
      end)

    section = %Section{
      key: :shared,
      label: "Shared",
      nodes: folder_nodes ++ unfiled_nodes,
      drop_target: true,
      dnd_section_id: "shared",
      dnd_kind: :chat,
      empty_message: "No shared chats yet",
      target: ctx.target
    }

    sections ++ [section]
  end

  defp maybe_add_personal(sections, _tree, filter, _eid, %{in_workspace?: true})
       when filter not in [:all, :personal],
       do: sections

  defp maybe_add_personal(
         sections,
         %TreeData{} = tree,
         _filter,
         editing_folder_id,
         %{in_workspace?: in_workspace?} = ctx
       ) do
    folder_nodes =
      Enum.map(tree.personal_folders, fn folder ->
        folder_to_node(
          folder,
          "personal",
          tree.threads_by_conversation,
          in_workspace?,
          editing_folder_id,
          ctx
        )
      end)

    empty_msg =
      if in_workspace?,
        do: "No personal chats in this workspace",
        else: "No chats yet"

    section =
      if in_workspace? do
        # Workspace personal: flat list (folders + unfiled flattened, no date headers)
        flat_unfiled =
          Enum.flat_map(tree.personal_unfiled_by_date, fn {_label, convs} ->
            Enum.map(convs, fn conv ->
              conversation_to_leaf(conv, "personal", tree.threads_by_conversation, ctx)
            end)
          end)

        %Section{
          key: :personal,
          label: "Personal",
          nodes: folder_nodes ++ flat_unfiled,
          drop_target: true,
          dnd_section_id: "personal",
          dnd_kind: :chat,
          empty_message: empty_msg,
          target: ctx.target
        }
      else
        # Personal-only mode: date-grouped. Folders prepended as a "" group.
        date_groups =
          Enum.map(tree.personal_unfiled_by_date, fn {label, convs} ->
            leaves =
              Enum.map(convs, fn conv ->
                conversation_to_leaf(conv, "personal", tree.threads_by_conversation, ctx)
              end)

            {label, leaves}
          end)

        grouped =
          case folder_nodes do
            [] -> date_groups
            _ -> [{"", folder_nodes} | date_groups]
          end

        %Section{
          key: :personal,
          label: nil,
          nodes: grouped,
          date_grouped?: true,
          drop_target: true,
          dnd_section_id: "personal",
          dnd_kind: :chat,
          empty_message: empty_msg,
          target: ctx.target
        }
      end

    sections ++ [section]
  end

  defp folder_to_node(folder, section, threads, show_share?, editing_folder_id, ctx) do
    target = ctx.target

    child_folders =
      Enum.map(folder.children || [], fn child ->
        folder_to_node(child, section, threads, show_share?, editing_folder_id, ctx)
      end)

    leaf_ctx = Map.put(ctx, :in_workspace?, show_share?)

    conversations =
      Enum.map(folder.conversations || [], fn conv ->
        conversation_to_leaf(conv, section, threads, leaf_ctx)
      end)

    Node.new_folder(
      id: folder.id,
      label: folder.name,
      icon: "lucide-folder",
      resource_type: :folder,
      draggable: true,
      children: child_folders,
      conversations: conversations,
      actions: folder_actions(folder, show_share?, target),
      editing?: editing_folder_id == folder.id,
      editor: %{
        submit_event: "submit_rename_folder",
        cancel_event: "cancel_rename_folder",
        target: target,
        value: folder.name
      },
      create_child_event: %{
        event: "create_conversation_in_folder",
        values: %{"folder-id" => folder.id},
        target: target,
        label: "New chat",
        icon: "lucide-plus"
      },
      click_event: %{event: "toggle_folder", values: %{"folder-id" => folder.id}, target: target}
    )
  end

  defp folder_actions(folder, show_share?, target) do
    share_action(
      folder,
      show_share?,
      "share_folder",
      "unshare_folder",
      "folder-id",
      folder.id,
      target
    ) ++
      [
        Action.new(
          icon: "lucide-pencil",
          event: "start_rename_folder",
          values: %{"folder-id" => folder.id},
          target: target,
          title: "Rename"
        ),
        Action.new(
          icon: "lucide-trash-2",
          event: "delete_folder",
          values: %{"folder-id" => folder.id},
          target: target,
          title: "Delete",
          style: :danger,
          confirm: "Delete this folder?"
        )
      ]
  end

  defp conversation_to_leaf(conv, _section, threads_map, ctx) do
    threads =
      Map.get(threads_map, conv.id, [])
      |> Enum.map(fn thread ->
        Node.new_leaf(
          id: thread.id,
          label: thread.title || "Thread",
          icon: "lucide-corner-down-right",
          resource_type: :conversation,
          click_event: %{
            event: "open_thread_in_parent",
            values: %{
              "parent_id" => conv.id,
              "thread_id" => thread.id,
              "label" => conv.title || "Untitled conversation"
            },
            target: nil
          }
        )
      end)

    favorited? = MapSet.member?(ctx.favorited_ids, conv.id)

    Node.new_leaf(
      id: conv.id,
      label: conv.title || "Untitled conversation",
      icon: if(conv.is_multiplayer, do: "lucide-users", else: "lucide-messages-square"),
      resource_type: :conversation,
      draggable: true,
      data_attrs: %{"conversation-id" => conv.id, "folder-id" => conv.folder_id || ""},
      subtitle: relative_time(Map.get(conv, :last_message_at)),
      subnodes: threads,
      actions: conversation_actions(conv, ctx.in_workspace?, ctx.target, favorited?),
      click_event: %{
        event: "open_tab",
        values: %{
          "type" => "conversation",
          "id" => conv.id,
          "label" => conv.title || "Untitled conversation"
        },
        target: nil
      }
    )
  end

  defp conversation_actions(conv, show_share?, target, favorited?) do
    share_action(
      conv,
      show_share?,
      "share_conversation",
      "unshare_conversation",
      "id",
      conv.id,
      target
    ) ++
      [
        Action.new(
          icon: if(favorited?, do: "magus-star-filled", else: "lucide-star"),
          event: "toggle_favorite_conversation",
          values: %{"id" => conv.id},
          target: target,
          title: if(favorited?, do: "Remove favorite", else: "Add favorite"),
          style: if(favorited?, do: :active, else: :default)
        ),
        Action.new(
          icon: "lucide-trash-2",
          event: "delete_conversation",
          values: %{"id" => conv.id},
          target: target,
          title: "Delete",
          style: :danger,
          confirm: "Delete this conversation?"
        )
      ]
  end

  defp share_action(_record, false, _share_event, _unshare_event, _key, _id, _target), do: []

  defp share_action(record, true, share_event, unshare_event, key, id, target) do
    if Map.get(record, :is_shared_to_workspace, false) do
      [
        Action.new(
          icon: "lucide-lock",
          event: unshare_event,
          values: %{key => id},
          target: target,
          title: "Make private"
        )
      ]
    else
      [
        Action.new(
          icon: "lucide-users",
          event: share_event,
          values: %{key => id},
          target: target,
          title: "Share with team"
        )
      ]
    end
  end

  defp relative_time(nil), do: nil

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86_400)}d"
      true -> "#{div(diff, 604_800)}w"
    end
  end
end
