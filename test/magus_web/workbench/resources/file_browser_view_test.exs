defmodule MagusWeb.Workbench.Resources.FileBrowserViewTest do
  @moduledoc """
  Feature tests for the file browser view.

  The view is rendered as an isolated LiveView so we can drive it directly
  with explicit session params (mirroring how the WorkbenchLive embeds it
  via `live_render(... sticky: true, session: %{...})`).
  """
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators

  alias Phoenix.LiveViewTest

  defp mount_browser(user, opts \\ []) do
    session = %{
      "user_id" => user.id,
      "tab_id" => "tab-test",
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "scope" => Keyword.get(opts, :scope, "my_files"),
      "id" => Keyword.get(opts, :id),
      "filters" => Keyword.get(opts, :filters, %{}),
      "sort" => Keyword.get(opts, :sort, "updated_at:desc"),
      "q" => Keyword.get(opts, :q, "")
    }

    LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      MagusWeb.Workbench.Resources.FileBrowserView,
      session: session
    )
  end

  defp create_text_file(user, name, attrs \\ %{}) do
    base = %{
      name: name,
      type: :text,
      mime_type: "text/plain",
      file_path: "f/#{name}-#{System.unique_integer([:positive])}",
      file_size: 1
    }

    {:ok, file} = Magus.Files.create_file(Map.merge(base, attrs), actor: user)
    file
  end

  defp create_image_file(user, name, attrs \\ %{}) do
    base = %{
      name: name,
      type: :image,
      mime_type: "image/png",
      file_path: "f/#{name}-#{System.unique_integer([:positive])}",
      file_size: 1
    }

    {:ok, file} = Magus.Files.create_file(Map.merge(base, attrs), actor: user)
    file
  end

  describe "my_files scope" do
    test "renders a folder, a loose file, and the My Files breadcrumb" do
      user = generate(user())
      ensure_workspace_plan(user)

      _folder = generate(folder(actor: user, name: "MyFolder", kind: :files))
      _file = create_text_file(user, "loose.txt")

      {:ok, _view, html} = mount_browser(user)

      assert html =~ "My Files"
      assert html =~ "MyFolder"
      assert html =~ "loose.txt"
    end
  end

  describe "type filter" do
    test "filters out non-image files when type=image" do
      user = generate(user())
      ensure_workspace_plan(user)

      _img = create_image_file(user, "photo.png")
      _pdf = create_text_file(user, "doc.pdf", %{type: :document, mime_type: "application/pdf"})

      {:ok, _view, html} = mount_browser(user, filters: %{"type" => "image"})

      assert html =~ "photo.png"
      refute html =~ "doc.pdf"
    end
  end

  describe "click navigation" do
    test "click on a folder card broadcasts a navigate request to the workbench shell" do
      user = generate(user())
      ensure_workspace_plan(user)

      f = generate(folder(actor: user, name: "ClickMe", kind: :files))

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
      )

      {:ok, view, _html} = mount_browser(user)

      view
      |> LiveViewTest.element(~s([data-entry-kind="folder"][data-entry-id="#{f.id}"]))
      |> LiveViewTest.render_click()

      assert_receive {:file_browser_navigate, %{scope: "folder", id: id}}, 500
      assert id == f.id
    end

    test "click on a file card navigates to /files/:id" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "click-me.txt")

      {:ok, view, _html} = mount_browser(user)

      assert {:error, {:live_redirect, %{to: target}}} =
               view
               |> LiveViewTest.element(~s([data-entry-kind="file"][data-entry-id="#{file.id}"]))
               |> LiveViewTest.render_click()

      assert target == "/files/#{file.id}"
    end
  end

  describe "search input" do
    test "broadcasts a file_browser_patch with the query" do
      user = generate(user())
      ensure_workspace_plan(user)

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
      )

      {:ok, view, _html} = mount_browser(user)

      view
      |> LiveViewTest.form("form[phx-change=\"search_input\"]", %{"q" => "needle"})
      |> LiveViewTest.render_change()

      assert_receive {:file_browser_patch, %{overrides: %{"q" => "needle"}}}, 500
    end
  end

  describe "view-mode toggle" do
    test "persists view_mode to user.ui_preferences[\"file_browser_view\"]" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, view, _html} = mount_browser(user)

      LiveViewTest.render_hook(view, "set_view_mode", %{"mode" => "list"})

      {:ok, reloaded} = Magus.Accounts.get_user(user.id, authorize?: false)
      assert reloaded.ui_preferences["file_browser_view"] == "list"
    end
  end

  describe "trash scope" do
    test "shows soft-deleted files only" do
      user = generate(user())
      ensure_workspace_plan(user)

      visible = create_text_file(user, "visible.txt")
      to_trash = create_text_file(user, "trashed.txt")

      {:ok, _} = Magus.Files.soft_delete_file(to_trash, actor: user)

      {:ok, _view, html} = mount_browser(user, scope: "trash")

      assert html =~ "trashed.txt"
      refute html =~ "visible.txt"
      assert html =~ "Trash"

      # And the visible file still appears in my_files.
      {:ok, _view, my_files_html} = mount_browser(user, scope: "my_files")
      assert my_files_html =~ visible.name
    end
  end

  describe "empty state" do
    test "renders 'No files yet' message when my_files scope is empty" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, _view, html} = mount_browser(user)

      assert html =~ "No files yet"
    end

    test "renders 'Trash is empty' message when trash scope is empty" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, _view, html} = mount_browser(user, scope: "trash")

      assert html =~ "Trash is empty"
    end
  end

  describe "rename modal" do
    test "rename_entry opens the modal pre-filled with the file's current name" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "before-rename.txt")

      {:ok, view, _html} = mount_browser(user)

      html =
        LiveViewTest.render_hook(view, "rename_entry", %{"kind" => "file", "id" => file.id})

      assert html =~ "phx-submit=\"submit_rename\""
      assert html =~ "before-rename.txt"
    end

    test "submit_rename updates the file in the DB and clears the rename target" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "old-name.txt")

      {:ok, view, _html} = mount_browser(user)

      LiveViewTest.render_hook(view, "rename_entry", %{"kind" => "file", "id" => file.id})

      html =
        LiveViewTest.render_hook(view, "submit_rename", %{
          "kind" => "file",
          "id" => file.id,
          "name" => "new-name.txt"
        })

      # Modal closed (no rename submit form in DOM after success).
      refute html =~ "phx-submit=\"submit_rename\""

      {:ok, updated} = Magus.Files.get_file(file.id, actor: user)
      assert updated.name == "new-name.txt"
    end

    test "cancel_rename clears the rename target without changing the file" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "keep-me.txt")

      {:ok, view, _html} = mount_browser(user)

      LiveViewTest.render_hook(view, "rename_entry", %{"kind" => "file", "id" => file.id})
      html = LiveViewTest.render_hook(view, "cancel_rename", %{})

      refute html =~ "phx-submit=\"submit_rename\""

      {:ok, unchanged} = Magus.Files.get_file(file.id, actor: user)
      assert unchanged.name == "keep-me.txt"
    end
  end

  describe "folder picker modal" do
    test "move_entry opens the folder picker with the 'Move to' header" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "movable.txt")

      {:ok, view, _html} = mount_browser(user)

      html = LiveViewTest.render_hook(view, "move_entry", %{"kind" => "file", "id" => file.id})

      assert html =~ "Move to"
      assert html =~ "phx-click=\"confirm_move\""
    end

    test "confirm_move with a folder_id moves the file into that folder" do
      user = generate(user())
      ensure_workspace_plan(user)

      target_folder = generate(folder(actor: user, name: "Target"))
      file = create_text_file(user, "to-move.txt")

      {:ok, view, _html} = mount_browser(user)

      LiveViewTest.render_hook(view, "move_entry", %{"kind" => "file", "id" => file.id})

      LiveViewTest.render_hook(view, "confirm_move", %{"folder-id" => target_folder.id})

      {:ok, moved} = Magus.Files.get_file(file.id, actor: user)
      assert moved.folder_id == target_folder.id
    end

    test "confirm_move with empty folder_id moves the file to root (folder_id: nil)" do
      user = generate(user())
      ensure_workspace_plan(user)

      parent = generate(folder(actor: user, name: "Parent"))
      file = create_text_file(user, "in-folder.txt", %{folder_id: parent.id})

      {:ok, view, _html} = mount_browser(user, scope: "folder", id: parent.id)

      LiveViewTest.render_hook(view, "move_entry", %{"kind" => "file", "id" => file.id})
      LiveViewTest.render_hook(view, "confirm_move", %{"folder-id" => ""})

      {:ok, moved} = Magus.Files.get_file(file.id, actor: user)
      assert is_nil(moved.folder_id)
    end

    test "cancel_move clears the move target" do
      user = generate(user())
      ensure_workspace_plan(user)

      file = create_text_file(user, "cancel-me.txt")

      {:ok, view, _html} = mount_browser(user)

      html = LiveViewTest.render_hook(view, "move_entry", %{"kind" => "file", "id" => file.id})
      assert html =~ "Move to"

      html = LiveViewTest.render_hook(view, "cancel_move", %{})
      refute html =~ "Move to"
    end
  end

  describe "upload" do
    test "upload input is wired up on mount" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, _view, html} = mount_browser(user)

      # The TopBar renders the live_file_input + Upload button using the
      # `:files` upload config, so the page should contain a file input and
      # an Upload control.
      assert html =~ ~s(type="file")
      assert html =~ "Upload"
    end
  end
end
