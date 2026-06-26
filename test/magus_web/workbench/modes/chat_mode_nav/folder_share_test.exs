defmodule MagusWeb.Workbench.Modes.ChatModeNav.FolderShareTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  alias Magus.Chat

  describe "folder share / unshare in workspace mode" do
    test "share moves folder from Personal to Shared section", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Drafts", workspace_id: workspace.id}, actor: user)

      {:ok, view, _html} =
        conn
        |> log_in_user_with_workspace(user, workspace)
        |> live(~p"/chat")

      assert view
             |> element(
               "#chat-mode-nav-tree-tree-section-personal #chat-mode-nav-tree-tree-folder-#{folder.id}"
             )
             |> has_element?()

      view
      |> element(
        ~s|#chat-mode-nav-tree-tree-folder-#{folder.id} [data-actions="row"] button[phx-click="share_folder"]|
      )
      |> render_click()

      assert view
             |> element(
               "#chat-mode-nav-tree-tree-section-shared #chat-mode-nav-tree-tree-folder-#{folder.id}"
             )
             |> has_element?()

      reloaded =
        Chat.get_folder!(folder.id, actor: user)
        |> Ash.load!(:is_shared_to_workspace, actor: user)

      assert reloaded.is_shared_to_workspace == true

      view
      |> element(
        ~s|#chat-mode-nav-tree-tree-folder-#{folder.id} [data-actions="row"] button[phx-click="unshare_folder"]|
      )
      |> render_click()

      assert view
             |> element(
               "#chat-mode-nav-tree-tree-section-personal #chat-mode-nav-tree-tree-folder-#{folder.id}"
             )
             |> has_element?()
    end
  end
end
