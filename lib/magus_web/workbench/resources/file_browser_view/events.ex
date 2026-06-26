defmodule MagusWeb.Workbench.Resources.FileBrowserView.Events do
  @moduledoc """
  Menu-action event handlers for the file browser. Each function takes the
  socket plus the params Phoenix delivers and returns the standard
  `{:noreply, socket}` tuple. Side effects (DB writes, push_navigate, flashes)
  are encapsulated here so the LV module stays focused on mount + reload.

  Handlers that need to refresh the entries stream accept a `reload_fun`
  callback (the LV's private `reload_entries/1`) so persistence stays in the
  LV while domain logic lives here.
  """

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3, push_navigate: 2]
  import Phoenix.Component, only: [assign: 3]

  alias MagusWeb.Workbench.Signals

  @doc """
  Open a folder entry. Broadcasts a navigate request to `WorkbenchLive`
  so the parent can `push_patch` to the new URL — this avoids the full
  remount that `push_navigate` from a sticky child LV would trigger.
  """
  def open_folder_entry(socket, %{"id" => id}) do
    broadcast_navigate(socket, "folder", id)
    {:noreply, socket}
  end

  @doc """
  Open a file entry. Files open in a brand-new tab type (file detail view)
  so a true navigate/remount is required.
  """
  def open_file_entry(socket, %{"id" => id}) do
    {:noreply, push_navigate(socket, to: "/files/#{id}")}
  end

  @doc """
  Navigate via a breadcrumb path. Breadcrumbs sit inside `TopBar` (a
  LiveComponent rendered inside this sticky child LV), so a plain
  `<.link patch>` would only patch the child URL, not the parent shell.
  Forward the path to `WorkbenchLive` instead.
  """
  def navigate_breadcrumb(socket, %{"path" => path}) when is_binary(path) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      Signals.workbench_user_topic(socket.assigns.user.id),
      {:file_browser_navigate_path, path}
    )

    {:noreply, socket}
  end

  def navigate_breadcrumb(socket, _params), do: {:noreply, socket}

  defp broadcast_navigate(socket, scope, id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      Signals.workbench_user_topic(socket.assigns.user.id),
      {:file_browser_navigate, %{scope: scope, id: id}}
    )
  end

  @doc """
  Open the rename modal for the selected entry.
  """
  def rename_entry(socket, %{"kind" => kind, "id" => id}) do
    {:noreply,
     socket
     |> assign(:rename_target, %{kind: kind, id: id})
     |> assign(:menu_for, nil)}
  end

  @doc """
  Cancel any in-progress rename.
  """
  def cancel_rename(socket, _params),
    do: {:noreply, assign(socket, :rename_target, nil)}

  @doc """
  Submit a rename. Dispatches on `"kind"` to rename a file or folder, then
  calls `reload_fun` on success to refresh the stream.
  """
  def submit_rename(socket, params, reload_fun)

  def submit_rename(socket, %{"kind" => "folder", "id" => id, "name" => name}, reload_fun) do
    user = socket.assigns.user

    case Magus.Chat.get_folder(id, actor: user) do
      {:ok, folder} ->
        case Magus.Chat.update_folder(folder, %{name: name}, actor: user) do
          {:ok, _} ->
            {:noreply, socket |> assign(:rename_target, nil) |> reload_fun.()}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not rename folder."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def submit_rename(socket, %{"kind" => "file", "id" => id, "name" => name}, reload_fun) do
    user = socket.assigns.user

    case Magus.Files.get_file(id, actor: user) do
      {:ok, file} ->
        case Magus.Files.update_file(file, %{name: name}, actor: user) do
          {:ok, _} ->
            {:noreply, socket |> assign(:rename_target, nil) |> reload_fun.()}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Could not rename file."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Toggle a file's `is_template` flag.
  """
  def toggle_template_entry(socket, %{"id" => id}, reload_fun) do
    user = socket.assigns.user

    result =
      case Magus.Files.get_file(id, actor: user) do
        {:ok, file} ->
          Magus.Files.update_file(file, %{is_template: !file.is_template}, actor: user)

        error ->
          error
      end

    socket =
      case result do
        {:ok, _} ->
          socket |> assign(:menu_for, nil) |> reload_fun.()

        _ ->
          socket
          |> assign(:menu_for, nil)
          |> put_flash(:error, gettext("Could not toggle template flag."))
      end

    {:noreply, socket}
  end

  @doc """
  Share an entry. Dispatches on `"kind"`: a file is shared into its workspace
  via a viewer grant; a folder is shared via the team-level helper.
  """
  def share_entry(socket, params, reload_fun)

  def share_entry(socket, %{"kind" => "file", "id" => id}, reload_fun) do
    user = socket.assigns.user

    with {:ok, file} <- Magus.Files.get_file(id, actor: user),
         ws_id when not is_nil(ws_id) <- file.workspace_id,
         {:ok, _} <-
           Magus.Workspaces.grant_access(
             %{
               resource_type: :file,
               resource_id: file.id,
               grantee_type: :workspace,
               grantee_id: ws_id,
               role: :viewer
             },
             actor: user
           ) do
      {:noreply, socket |> assign(:menu_for, nil) |> reload_fun.()}
    else
      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not share file.")) |> assign(:menu_for, nil)}
    end
  end

  def share_entry(socket, %{"kind" => "folder", "id" => id}, reload_fun) do
    user = socket.assigns.user

    case Magus.Chat.get_folder(id, actor: user) do
      {:ok, folder} ->
        case Magus.Chat.share_folder_to_team(folder, actor: user) do
          {:ok, _} ->
            {:noreply, socket |> assign(:menu_for, nil) |> reload_fun.()}

          _ ->
            {:noreply,
             put_flash(socket, :error, gettext("Could not share folder."))
             |> assign(:menu_for, nil)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Move an entry to trash. Dispatches on `"kind"` to delete the file or folder.
  """
  def trash_entry(socket, params, reload_fun)

  def trash_entry(socket, %{"kind" => "file", "id" => id}, reload_fun) do
    user = socket.assigns.user

    result =
      case Magus.Files.get_file(id, actor: user) do
        {:ok, file} -> Magus.Files.delete_file(file, actor: user)
        error -> error
      end

    socket =
      case result do
        {:ok, _} ->
          socket |> assign(:menu_for, nil) |> reload_fun.()

        :ok ->
          socket |> assign(:menu_for, nil) |> reload_fun.()

        _ ->
          socket
          |> assign(:menu_for, nil)
          |> put_flash(:error, gettext("Could not move file to trash."))
      end

    {:noreply, socket}
  end

  def trash_entry(socket, %{"kind" => "folder", "id" => id}, reload_fun) do
    user = socket.assigns.user

    result =
      case Magus.Chat.get_folder(id, actor: user) do
        {:ok, folder} -> Magus.Chat.delete_folder(folder, actor: user)
        error -> error
      end

    socket =
      case result do
        {:ok, _} ->
          socket |> assign(:menu_for, nil) |> reload_fun.()

        :ok ->
          socket |> assign(:menu_for, nil) |> reload_fun.()

        _ ->
          socket
          |> assign(:menu_for, nil)
          |> put_flash(:error, gettext("Could not move folder to trash."))
      end

    {:noreply, socket}
  end

  @doc """
  Generate a presigned URL for the file and push an "open-url" event so the
  client opens it in a new tab.
  """
  def download_entry(socket, %{"id" => id}) do
    user = socket.assigns.user

    case Magus.Files.get_file(id, actor: user) do
      {:ok, %{file_path: path}} ->
        case Magus.Files.Storage.get_url(path) do
          {:ok, url} -> {:noreply, push_event(socket, "open-url", %{url: url})}
          _ -> {:noreply, put_flash(socket, :error, gettext("Could not generate download URL."))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @doc """
  Open or create the companion conversation for a file and navigate to it.
  """
  def open_entry_chat(socket, %{"id" => id}) do
    user = socket.assigns.user

    case Magus.Chat.find_or_create_companion_conversation(:file, id, actor: user) do
      {:ok, conv} -> {:noreply, push_navigate(socket, to: "/chat/#{conv.id}")}
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not open chat for this file."))}
    end
  end

  @doc """
  Open the folder picker modal to start a move.
  """
  def move_entry(socket, %{"kind" => kind, "id" => id}) do
    {:noreply,
     socket
     |> assign(:menu_for, nil)
     |> assign(:move_target, %{kind: kind, id: id})}
  end

  @doc """
  Cancel an in-progress move.
  """
  def cancel_move(socket, _params),
    do: {:noreply, assign(socket, :move_target, nil)}

  @doc """
  Confirm a move into the chosen folder (empty string = root).
  """
  def confirm_move(socket, %{"folder-id" => folder_id}, reload_fun) do
    user = socket.assigns.user
    target = socket.assigns.move_target
    folder_id = if folder_id == "", do: nil, else: folder_id

    result =
      case target do
        %{kind: "file", id: id} ->
          case Magus.Files.get_file(id, actor: user) do
            {:ok, file} ->
              Magus.Files.move_file_to_context(
                file,
                %{folder_id: folder_id, conversation_id: nil},
                actor: user
              )

            error ->
              error
          end

        %{kind: "folder", id: id} ->
          case Magus.Chat.get_folder(id, actor: user) do
            {:ok, folder} -> Magus.Chat.move_folder(folder, %{parent_id: folder_id}, actor: user)
            error -> error
          end

        _ ->
          :ok
      end

    socket =
      case result do
        {:ok, _} ->
          socket |> assign(:move_target, nil) |> reload_fun.()

        :ok ->
          socket |> assign(:move_target, nil) |> reload_fun.()

        _ ->
          socket
          |> assign(:move_target, nil)
          |> put_flash(:error, gettext("Could not move item."))
      end

    {:noreply, socket}
  end
end
