defmodule MagusWeb.Workbench.Modes.ChatModeNavTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  describe "folder expand/collapse" do
    test "toggling persists state via UserFolderState", %{conn: conn} do
      user = generate(user())
      folder = Magus.Chat.create_folder!(%{name: "Drafts"}, actor: user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/chat")

      view
      |> element(
        ~s|#chat-mode-nav-tree-tree-folder-#{folder.id} button[phx-click="toggle_folder"]|
      )
      |> render_click()

      states = Magus.Chat.my_folder_states!(actor: user)
      assert Enum.any?(states, &(&1.folder_id == folder.id and &1.is_expanded))
    end
  end

  describe "favorite toggle" do
    test "clicking favorite on a conversation creates the favorite and surfaces a Favorites section",
         %{conn: conn} do
      user = generate(user())
      conv = Magus.Chat.create_conversation!(%{title: "Pin me"}, actor: user)

      {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/chat")

      refute html =~ "Favorites ("

      view
      |> element(
        ~s|#chat-mode-nav-tree-tree-leaf-#{conv.id} [data-actions="row"] button[phx-click="toggle_favorite_conversation"]|
      )
      |> render_click()

      assert {:ok, _} = Magus.Chat.get_conversation_favorite(conv.id, actor: user)
      assert render(view) =~ "Favorites (1)"
    end

    test "favorited conversations only render in the Favorites section, marked active",
         %{conn: conn} do
      user = generate(user())
      conv = Magus.Chat.create_conversation!(%{title: "Already pinned"}, actor: user)
      Magus.Chat.create_conversation_favorite!(%{conversation_id: conv.id}, actor: user)

      {:ok, _view, html} = conn |> log_in_user(user) |> live(~p"/chat")

      # Favorited convs are hidden from the regular Personal section to avoid
      # showing the same row twice; only the Favorites row should remain.
      personal_row = ~r|<li id="chat-mode-nav-tree-tree-leaf-#{conv.id}".*?</li>|s
      favorites_row = ~r|<li id="chat-mode-nav-tree-tree-favorites-leaf-#{conv.id}".*?</li>|s

      refute Regex.run(personal_row, html)
      assert [favorites_match] = Regex.run(favorites_row, html)
      assert favorites_match =~ "toggle_favorite_conversation"
      assert favorites_match =~ "text-warning"
    end
  end

  describe "folder delete" do
    test "deleting a folder removes it from the tree", %{conn: conn} do
      user = generate(user())
      folder = Magus.Chat.create_folder!(%{name: "Junk"}, actor: user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/chat")

      view
      |> element(
        ~s|#chat-mode-nav-tree-tree-folder-#{folder.id} [data-actions="row"] button[phx-click="delete_folder"]|
      )
      |> render_click()

      refute has_element?(view, "#chat-mode-nav-tree-tree-folder-#{folder.id}")
    end
  end

  describe "drag and drop" do
    test "move_conversation in same section files it under the target folder", %{conn: conn} do
      user = generate(user())
      folder = Magus.Chat.create_folder!(%{name: "Drafts"}, actor: user)
      conv = Magus.Chat.create_conversation!(%{title: "c"}, actor: user)

      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/chat")

      render_hook(
        view |> element("#chat-mode-nav-tree-tree-section-personal"),
        "move_conversation",
        %{"conversation_id" => conv.id, "folder_id" => folder.id, "section" => "personal"}
      )

      reloaded = Magus.Chat.get_conversation!(conv.id, actor: user)
      assert reloaded.folder_id == folder.id
    end

    test "cross-section move_conversation event is a no-op", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      shared_folder =
        Magus.Chat.create_folder!(%{name: "Team", workspace_id: workspace.id}, actor: user)

      Magus.Chat.share_folder_to_team!(shared_folder, actor: user)

      personal_conv =
        Magus.Chat.create_conversation!(
          %{title: "c", workspace_id: workspace.id},
          actor: user
        )

      {:ok, view, _html} =
        conn
        |> log_in_user_with_workspace(user, workspace)
        |> live(~p"/chat")

      render_hook(
        view |> element("#chat-mode-nav-tree-tree-section-shared"),
        "move_conversation",
        %{
          "conversation_id" => personal_conv.id,
          "folder_id" => shared_folder.id,
          "section" => "shared"
        }
      )

      reloaded = Magus.Chat.get_conversation!(personal_conv.id, actor: user)
      assert reloaded.folder_id == nil
    end
  end

  describe "toolbar" do
    test "+ folder creates a new personal folder", %{conn: conn} do
      user = generate(user())
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/chat")

      view
      |> element("button[phx-click=\"begin_new_folder\"]")
      |> render_click()

      view
      |> form("form[phx-submit=\"create_folder_root\"]", %{"name" => "MyFolder"})
      |> render_submit()

      folders = Magus.Chat.my_folders!(actor: user)
      assert Enum.any?(folders, &(&1.name == "MyFolder"))

      assert has_element?(view, "[data-folder-id]", "MyFolder")
    end
  end
end
