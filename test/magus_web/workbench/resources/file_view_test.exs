defmodule MagusWeb.Workbench.Resources.FileViewTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  import Phoenix.LiveViewTest,
    only: [render: 1, render_click: 1, render_hook: 3, assert_redirect: 3]

  alias Phoenix.LiveViewTest
  alias MagusWeb.Workbench.Signals, as: WorkbenchSignals

  defp mount_view(file_id, user_id) do
    LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      MagusWeb.Workbench.Resources.FileView,
      session: %{"file_id" => file_id, "user_id" => user_id, "tab_id" => "tab_test"}
    )
  end

  defp mount_view_with(file_id, user_id, role, tab_id) do
    LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      MagusWeb.Workbench.Resources.FileView,
      session: %{
        "file_id" => file_id,
        "user_id" => user_id,
        "tab_id" => tab_id,
        "role" => role
      }
    )
  end

  defp create_library_file(user, attrs) do
    base = %{
      name: "f.txt",
      type: :text,
      mime_type: "text/plain",
      file_path: "f/f.txt",
      file_size: 1
    }

    {:ok, file} = Magus.Files.create_file(Map.merge(base, attrs), actor: user)
    file
  end

  describe "meta sidebar" do
    test "renders file name, status, size, mime, and a Download button" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "doc.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_path: "f/doc.pdf",
          file_size: 12345
        })

      {:ok, _view, html} = mount_view(file.id, user.id)

      assert html =~ "doc.pdf"
      assert html =~ "KB"
      assert html =~ "application/pdf"
      assert html =~ ~s(data-action="download")
    end
  end

  describe "generic fallback" do
    test "renders generic viewer when no specialized viewer applies" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "weird.bin",
          type: :document,
          mime_type: "application/octet-stream",
          file_path: "f/weird.bin",
          file_size: 1
        })

      {:ok, _view, html} = mount_view(file.id, user.id)

      assert html =~ ~s(data-viewer="generic")
      assert html =~ "weird.bin"
    end
  end

  describe "specialized viewers" do
    test "image type renders <img>" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "pic.png",
          type: :image,
          mime_type: "image/png",
          file_path: "f/pic.png",
          file_size: 100
        })

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="image")
      assert html =~ ~s(<img )
    end

    test "video type renders <video>" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "v.mp4",
          type: :video,
          mime_type: "video/mp4",
          file_path: "f/v.mp4",
          file_size: 100
        })

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="video")
      assert html =~ "<video"
    end

    test "application/pdf mime renders pdf viewer wrapper" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "doc.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_path: "f/doc.pdf",
          file_size: 100
        })

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="pdf")
    end

    test "text type renders body fetched from Storage" do
      user = generate(user())
      ensure_workspace_plan(user)

      relative_path = "f/note-#{System.unique_integer([:positive])}.txt"
      {:ok, _} = Magus.Files.Storage.store(relative_path, "hello world")

      file =
        create_library_file(user, %{
          name: "note.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: relative_path,
          file_size: byte_size("hello world")
        })

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="text")
      assert html =~ "hello world"
    end

    test "document type with chunks renders concatenated text" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "report.docx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          file_path: "f/report.docx",
          file_size: 100
        })

      {:ok, file} = Magus.Files.update_file_status(file, %{status: :ready}, actor: user)

      {:ok, _c1} =
        Magus.Files.create_chunk(
          %{file_id: file.id, content: "First chunk.", position: 0, token_count: 2},
          authorize?: false
        )

      {:ok, _c2} =
        Magus.Files.create_chunk(
          %{file_id: file.id, content: "Second chunk.", position: 1, token_count: 2},
          authorize?: false
        )

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="document")
      assert html =~ "First chunk."
      assert html =~ "Second chunk."
    end

    test "document type with no chunks falls back to generic viewer" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "still-processing.docx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          file_path: "f/still-processing.docx",
          file_size: 100
        })

      {:ok, _view, html} = mount_view(file.id, user.id)
      assert html =~ ~s(data-viewer="generic")
    end
  end

  describe "actions" do
    test "share toggle creates a workspace grant" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      file =
        create_library_file(user, %{
          name: "share.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: "f/share.txt",
          file_size: 1,
          workspace_id: ws.id
        })

      {:ok, view, _html} = mount_view(file.id, user.id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-action="share-to-workspace"]))
      |> Phoenix.LiveViewTest.render_click()

      {:ok, grants} = Magus.Workspaces.list_access_for_resource(:file, file.id, actor: user)
      assert Enum.any?(grants, fn g -> g.grantee_type == :workspace and g.grantee_id == ws.id end)
    end

    test "unshare toggle removes the workspace grant" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      file =
        create_library_file(user, %{
          name: "shared.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: "f/shared.txt",
          file_size: 1,
          workspace_id: ws.id
        })

      # Grant first so the file is shared.
      {:ok, _} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :file,
            resource_id: file.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: user
        )

      {:ok, view, _html} = mount_view(file.id, user.id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-action="unshare-from-workspace"]))
      |> Phoenix.LiveViewTest.render_click()

      {:ok, grants} = Magus.Workspaces.list_access_for_resource(:file, file.id, actor: user)
      refute Enum.any?(grants, fn g -> g.grantee_type == :workspace and g.grantee_id == ws.id end)
    end

    test "delete destroys the file" do
      user = generate(user())
      ensure_workspace_plan(user)

      file =
        create_library_file(user, %{
          name: "todelete.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: "f/del.txt",
          file_size: 1
        })

      {:ok, view, _html} = mount_view(file.id, user.id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-action="delete"]))
      |> Phoenix.LiveViewTest.render_click()

      assert {:error, _} = Magus.Files.get_file(file.id, actor: user)
    end

    test "delete event with file: nil socket is a no-op (defensive)" do
      # Simulate: file was deleted between mount and a stale client click.
      # Build a socket with file: nil and verify the handler returns no_reply
      # without raising rather than crashing.
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:file, nil)
        |> Phoenix.Component.assign(:file_id, "00000000-0000-0000-0000-000000000000")
        |> Phoenix.Component.assign(:user, nil)
        |> Phoenix.Component.assign(:tab_id, "tab_test")

      assert {:noreply, _} =
               MagusWeb.Workbench.Resources.FileView.handle_event("delete", %{}, socket)

      assert {:noreply, _} =
               MagusWeb.Workbench.Resources.FileView.handle_event(
                 "share_to_workspace",
                 %{},
                 socket
               )

      assert {:noreply, _} =
               MagusWeb.Workbench.Resources.FileView.handle_event(
                 "unshare_from_workspace",
                 %{},
                 socket
               )
    end
  end

  describe "companion chat" do
    defp create_pdf_file(user) do
      base = %{
        name: "doc.pdf",
        type: :document,
        mime_type: "application/pdf",
        file_path: "f/doc.pdf",
        file_size: 1
      }

      {:ok, file} = Magus.Files.create_file(base, actor: user)
      file
    end

    test "Open chat header button appears when role == primary" do
      user = generate(user())
      ensure_workspace_plan(user)
      file = create_pdf_file(user)

      tab_id = "tab_open_chat_primary_#{System.unique_integer([:positive])}"

      {:ok, _view, html} = mount_view_with(file.id, user.id, "primary", tab_id)

      assert html =~ "Open chat"
      assert html =~ "data-file-open-chat"
    end

    test "clicking Open chat broadcasts open_companion and links a conversation" do
      user = generate(user())
      ensure_workspace_plan(user)
      file = create_pdf_file(user)

      tab_id = "tab_open_chat_click_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))

      {:ok, view, _html} = mount_view_with(file.id, user.id, "primary", tab_id)

      view
      |> LiveViewTest.element("[data-file-open-chat]")
      |> render_click()

      assert_receive {:workbench_companion, {:open, %{"type" => "conversation", "id" => _}}}, 500

      assert {:ok, _link} = Magus.Chat.get_companion_by_resource(:file, file.id, actor: user)
    end

    test "metadata sidebar hides when companion_open assign is true" do
      user = generate(user())
      ensure_workspace_plan(user)
      file = create_pdf_file(user)

      tab_id = "tab_meta_hide_#{System.unique_integer([:positive])}"

      {:ok, view, html} = mount_view_with(file.id, user.id, "primary", tab_id)
      assert html =~ ~s(aria-label="File details")

      send(
        view.pid,
        {:workbench_companion,
         {:open, %{"type" => "conversation", "id" => Ash.UUIDv7.generate()}}}
      )

      refute render(view) =~ ~s(aria-label="File details")
    end

    test "Open chat hidden + close-self button shown when role == companion" do
      user = generate(user())
      ensure_workspace_plan(user)
      file = create_pdf_file(user)

      tab_id = "tab_role_companion_#{System.unique_integer([:positive])}"

      {:ok, _view, html} = mount_view_with(file.id, user.id, "companion", tab_id)

      refute html =~ "Open chat"
      assert html =~ "lucide-x"
      assert html =~ ~s(phx-click="close_self_companion")
    end

    test "pdf:ask_about_selection opens companion and broadcasts selection" do
      user = generate(user())
      ensure_workspace_plan(user)
      file = create_pdf_file(user)

      tab_id = "tab_pdf_select_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))

      {:ok, view, _html} = mount_view_with(file.id, user.id, "primary", tab_id)

      payload = %{
        "text" => "selected text",
        "image" => "data:image/jpeg;base64,xx",
        "page" => 4
      }

      render_hook(view, "pdf:ask_about_selection", payload)

      assert_receive {:workbench_companion, {:open, %{"type" => "conversation", "id" => _}}}, 500

      assert_receive {:workbench_chrome, {:insert_text, "selected text"}}, 500

      assert_receive {:workbench_chrome, {:pdf_selection, broadcast_payload}}, 500
      assert broadcast_payload[:filename] == "doc.pdf"
      assert broadcast_payload[:text] == "selected text"
      assert broadcast_payload[:page] == 4
    end
  end

  describe "live updates" do
    test "broadcasting an update for the current workspace file refreshes the view" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      file =
        create_library_file(user, %{
          name: "live.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: "f/live.txt",
          file_size: 1,
          workspace_id: ws.id
        })

      {:ok, view, _html} = mount_view(file.id, user.id)

      MagusWeb.Endpoint.broadcast(
        "workspaces:#{ws.id}:files",
        "update",
        %{id: file.id, workspace_id: ws.id, action: :updated}
      )

      # Render-after-broadcast should still show the same file (refresh runs).
      assert render(view) =~ file.name
    end

    test "broadcasting a destroy navigates away from the view" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      file =
        create_library_file(user, %{
          name: "gone.txt",
          type: :text,
          mime_type: "text/plain",
          file_path: "f/gone.txt",
          file_size: 1,
          workspace_id: ws.id
        })

      {:ok, view, _html} = mount_view(file.id, user.id)

      MagusWeb.Endpoint.broadcast(
        "workspaces:#{ws.id}:files",
        "destroy",
        %{id: file.id, workspace_id: ws.id, action: :deleted}
      )

      assert_redirect(view, "/chat", 1000)
    end
  end
end
