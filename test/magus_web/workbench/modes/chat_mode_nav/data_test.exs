defmodule MagusWeb.Workbench.Modes.ChatModeNav.DataTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat
  alias MagusWeb.Workbench.Modes.ChatModeNav.Data
  alias MagusWeb.Workbench.Modes.ChatModeNav.Data.TreeData

  describe "load_tree/1 in personal mode" do
    test "returns folders, favorites, and unfiled conversations grouped by date" do
      user = generate(user())
      folder = Chat.create_folder!(%{name: "Drafts"}, actor: user)
      filed = Chat.create_conversation!(%{title: "filed", folder_id: folder.id}, actor: user)
      unfiled = Chat.create_conversation!(%{title: "unfiled"}, actor: user)
      fav = Chat.create_conversation!(%{title: "favorited"}, actor: user)
      Chat.create_conversation_favorite!(%{conversation_id: fav.id}, actor: user)

      tree =
        Data.load_tree(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_folders: %{to_string(folder.id) => true}
        })

      assert %TreeData{} = tree
      assert tree.in_workspace? == false
      assert Enum.any?(tree.favorites, &(&1.id == fav.id))

      [root_folder] = tree.personal_folders
      assert root_folder.id == folder.id
      assert Enum.any?(root_folder.conversations, &(&1.id == filed.id))

      flat_unfiled = Enum.flat_map(tree.personal_unfiled_by_date, fn {_lbl, cs} -> cs end)
      assert Enum.any?(flat_unfiled, &(&1.id == unfiled.id))
      refute Enum.any?(flat_unfiled, &(&1.id == filed.id))
    end

    test "search filters conversations by title" do
      user = generate(user())
      Chat.create_conversation!(%{title: "Alpha note"}, actor: user)
      Chat.create_conversation!(%{title: "Beta note"}, actor: user)

      tree =
        Data.load_tree(%{
          user: user,
          workspace_id: nil,
          search_query: "alpha",
          expanded_folders: %{}
        })

      flat = Enum.flat_map(tree.personal_unfiled_by_date, fn {_lbl, cs} -> cs end)
      titles = Enum.map(flat, & &1.title)
      assert "Alpha note" in titles
      refute "Beta note" in titles
    end

    test "shows at most 20 unfiled conversations, selected by recent message activity" do
      user = generate(user())

      # 20 conversations that each have a message -> non-nil last_message_at
      for i <- 1..20 do
        c = Chat.create_conversation!(%{title: "with-msg-#{i}"}, actor: user)
        generate(message(actor: user, conversation_id: c.id, text: "m#{i}"))
      end

      # A message-less conversation created last: it has the newest updated_at
      # but a nil last_message_at, so it must NOT crowd out the active ones.
      quiet = Chat.create_conversation!(%{title: "no-messages"}, actor: user)

      tree =
        Data.load_tree(%{user: user, workspace_id: nil, search_query: "", expanded_folders: %{}})

      flat = Enum.flat_map(tree.personal_unfiled_by_date, fn {_lbl, cs} -> cs end)
      ids = Enum.map(flat, & &1.id)

      assert length(flat) == 20
      refute quiet.id in ids
    end
  end

  describe "load_tree/1 in workspace mode" do
    test "splits shared and personal folders/conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      shared_folder =
        Chat.create_folder!(
          %{name: "Team Roadmap", workspace_id: workspace.id},
          actor: user
        )

      personal_folder =
        Chat.create_folder!(
          %{name: "Personal Notes", workspace_id: workspace.id},
          actor: user
        )

      Chat.share_folder_to_team!(shared_folder, actor: user)

      shared_conv =
        Chat.create_conversation!(
          %{title: "shared-conv", workspace_id: workspace.id, folder_id: shared_folder.id},
          actor: user
        )

      Chat.share_conversation_to_team!(shared_conv, actor: user)

      _personal_conv =
        Chat.create_conversation!(
          %{
            title: "personal-conv",
            workspace_id: workspace.id,
            folder_id: personal_folder.id
          },
          actor: user
        )

      favorited_in_ws =
        Chat.create_conversation!(%{title: "fav", workspace_id: workspace.id}, actor: user)

      Chat.create_conversation_favorite!(%{conversation_id: favorited_in_ws.id}, actor: user)

      tree =
        Data.load_tree(%{
          user: user,
          workspace_id: workspace.id,
          search_query: "",
          expanded_folders: %{}
        })

      assert tree.in_workspace? == true
      assert Enum.map(tree.shared_folders, & &1.id) == [shared_folder.id]
      assert Enum.map(tree.personal_folders, & &1.id) == [personal_folder.id]
      assert Enum.any?(tree.favorites, &(&1.id == favorited_in_ws.id))
    end

    test "nested folder building works at depth > 1" do
      user = generate(user())
      root = Chat.create_folder!(%{name: "Root"}, actor: user)
      child = Chat.create_folder!(%{name: "Child", parent_id: root.id}, actor: user)
      grandchild = Chat.create_folder!(%{name: "Grandchild", parent_id: child.id}, actor: user)

      deep_conv =
        Chat.create_conversation!(%{title: "deep", folder_id: grandchild.id}, actor: user)

      tree =
        Data.load_tree(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_folders: %{}
        })

      [root_node] = tree.personal_folders
      assert root_node.id == root.id
      [child_node] = root_node.children
      assert child_node.id == child.id
      [grandchild_node] = child_node.children
      assert grandchild_node.id == grandchild.id
      assert Enum.any?(grandchild_node.conversations, &(&1.id == deep_conv.id))
    end

    test "search auto-expands ancestors at depth > 1" do
      user = generate(user())
      root = Chat.create_folder!(%{name: "Root"}, actor: user)
      child = Chat.create_folder!(%{name: "ChildAlpha", parent_id: root.id}, actor: user)

      tree =
        Data.load_tree(%{
          user: user,
          workspace_id: nil,
          search_query: "alpha",
          expanded_folders: %{}
        })

      assert MapSet.member?(tree.auto_expanded_ids, child.id)
      assert MapSet.member?(tree.auto_expanded_ids, root.id)
    end
  end

  describe "to_sections/2" do
    test "personal mode produces a personal section without favorites if none" do
      user = generate(user())
      Magus.Chat.create_conversation!(%{title: "hi"}, actor: user)

      tree =
        MagusWeb.Workbench.Modes.ChatModeNav.Data.load_tree(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_folders: %{}
        })

      sections =
        MagusWeb.Workbench.Modes.ChatModeNav.Data.to_sections(tree,
          nav_filter: :all,
          editing_folder_id: nil,
          favorites_collapsed?: false,
          tree_target: "#chat-tree"
        )

      keys = Enum.map(sections, & &1.key)
      refute :favorites in keys
      assert :personal in keys
    end

    test "thread subnodes emit open_thread_in_parent with parent + thread ids" do
      user = generate(user())

      conv =
        Chat.create_conversation!(%{title: "parent conv"}, actor: user)

      {:ok, msg} =
        Chat.send_user_message(%{text: "hello", conversation_id: conv.id}, actor: user)

      {:ok, thread} =
        Chat.create_thread(
          %{parent_conversation_id: conv.id, branched_at_message_id: msg.id, title: "side"},
          actor: user
        )

      tree =
        Data.load_tree(%{user: user, workspace_id: nil, search_query: "", expanded_folders: %{}})

      sections =
        Data.to_sections(tree,
          nav_filter: :all,
          editing_folder_id: nil,
          favorites_collapsed?: false,
          tree_target: "#chat-tree"
        )

      # personal-only sections are date-grouped: nodes is [{label, leaves}, ...]
      leaf =
        sections
        |> Enum.flat_map(fn section ->
          case section.nodes do
            [{_label, _leaves} | _] = grouped -> Enum.flat_map(grouped, fn {_, l} -> l end)
            nodes -> nodes
          end
        end)
        |> Enum.find(&(&1.id == conv.id))

      assert leaf, "expected the parent conversation to appear as a leaf in the tree"

      [thread_node] = leaf.subnodes
      assert thread_node.id == thread.id
      assert thread_node.click_event.event == "open_thread_in_parent"
      assert thread_node.click_event.values["parent_id"] == conv.id
      assert thread_node.click_event.values["thread_id"] == thread.id
    end

    test "workspace mode produces shared + personal sections" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      Magus.Chat.create_conversation!(%{title: "p", workspace_id: workspace.id}, actor: user)

      tree =
        MagusWeb.Workbench.Modes.ChatModeNav.Data.load_tree(%{
          user: user,
          workspace_id: workspace.id,
          search_query: "",
          expanded_folders: %{}
        })

      sections =
        MagusWeb.Workbench.Modes.ChatModeNav.Data.to_sections(tree,
          nav_filter: :all,
          editing_folder_id: nil,
          favorites_collapsed?: false,
          tree_target: "#chat-tree"
        )

      keys = Enum.map(sections, & &1.key)
      assert :shared in keys
      assert :personal in keys
    end
  end
end
