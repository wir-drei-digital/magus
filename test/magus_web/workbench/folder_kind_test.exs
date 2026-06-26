defmodule MagusWeb.Workbench.FolderKindTest do
  @moduledoc """
  Folder creation in each UI context tags the folder with the right kind.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators
  import Phoenix.LiveViewTest

  describe "creation context sets kind" do
    test "file browser 'New folder' creates a :files folder", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/files")

      {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
      tab_id = session.active_tab_id

      browser =
        view
        |> find_live_child("tab-#{tab_id}")
        |> find_live_child("file-browser-#{tab_id}")

      browser |> element(~s(button[phx-click="start_new_folder"])) |> render_click()

      browser
      |> form(~s(form[phx-submit="submit_new_folder"]), %{name: "Browser folder"})
      |> render_submit()

      [folder] = Magus.Chat.my_folders!(actor: user)
      assert folder.name == "Browser folder"
      assert folder.kind == :files
    end

    test "conversation nav 'New folder' creates a :conversations folder", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element(~s(button[phx-click="begin_new_folder"])) |> render_click()

      view
      |> form(~s(form[phx-submit="create_folder_root"]), %{name: "Chat folder"})
      |> render_submit()

      [folder] = Magus.Chat.my_folders!(actor: user)
      assert folder.name == "Chat folder"
      assert folder.kind == :conversations
    end
  end

  describe "cross-context visibility" do
    test "a :files folder is hidden in conversation nav", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, _f} = Magus.Chat.create_folder(%{name: "FilesOnly", kind: :files}, actor: user)

      {:ok, _c} =
        Magus.Chat.create_folder(%{name: "ChatsOnly", kind: :conversations}, actor: user)

      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ "ChatsOnly"
      refute html =~ "FilesOnly"
    end

    test "a :conversations folder is hidden in file browser", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, _f} = Magus.Chat.create_folder(%{name: "FilesOnly", kind: :files}, actor: user)

      {:ok, _c} =
        Magus.Chat.create_folder(%{name: "ChatsOnly", kind: :conversations}, actor: user)

      {:ok, view, _html} = live(conn, ~p"/files")

      {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
      tab_id = session.active_tab_id

      browser =
        view
        |> find_live_child("tab-#{tab_id}")
        |> find_live_child("file-browser-#{tab_id}")

      html = render(browser)
      assert html =~ "FilesOnly"
      refute html =~ "ChatsOnly"
    end
  end
end
