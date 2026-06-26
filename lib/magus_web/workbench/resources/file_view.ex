defmodule MagusWeb.Workbench.Resources.FileView do
  @moduledoc """
  Read-only file detail view rendered in the workbench shell's main area
  when the user opens a file tab.

  Layout: viewer (left/center) + always-visible meta sidebar (right).
  This module provides only the generic fallback viewer; specialized
  image/pdf/video/text viewers are added in subsequent tasks.

  Session:
    - `"file_id"` — UUID of the file
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id hosting this view
    - `"role"` — optional `"primary"` (default) or `"companion"`
  """
  use MagusWeb, :live_view

  alias Magus.Files
  alias MagusWeb.Workbench.Signals, as: WorkbenchSignals

  @impl true
  def mount(_params, session, socket) do
    file_id = session["file_id"]
    user = session["user_id"] && Magus.Accounts.get_user!(session["user_id"])
    tab_id = session["tab_id"]
    role = session["role"] || "primary"

    case Files.get_file(file_id,
           actor: user,
           load: [:knowledge_collection, :folder, :is_shared_to_workspace]
         ) do
      {:ok, file} ->
        if connected?(socket) do
          Magus.Endpoint.subscribe(file_pubsub_topic(file))

          if tab_id do
            Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))
          end
        end

        {:ok,
         socket
         |> assign(:file, file)
         |> assign(:user, user)
         |> assign(:file_id, file_id)
         |> assign(:tab_id, tab_id)
         |> assign(:role, role)
         |> assign(:companion_open, false)
         |> assign(:download_url, download_url(file.file_path))}

      _ ->
        {:ok,
         socket
         |> assign(:file, nil)
         |> assign(:user, user)
         |> assign(:file_id, file_id)
         |> assign(:tab_id, tab_id)
         |> assign(:role, role)
         |> assign(:companion_open, false)}
    end
  end

  # The File resource publishes via Magus.Endpoint.broadcast on two
  # canonical topics — user-scoped ("files:files:<user_id>") from its
  # pub_sub block, and workspace-scoped ("workspaces:<ws_id>:files") from
  # the BroadcastWorkspaceEvent change module. Both wrap payloads in a
  # Phoenix.Socket.Broadcast struct, which we filter to the current file
  # before refreshing or navigating away.
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, socket) do
    cond do
      not matches_current_file?(payload, socket) ->
        {:noreply, socket}

      event == "destroy" ->
        {:noreply, push_navigate(socket, to: "/chat")}

      event == "update" ->
        {:noreply, refresh_file(socket)}

      true ->
        {:noreply, socket}
    end
  end

  # Tab-scoped companion lifecycle — drives the `:companion_open` flag, which
  # in turn hides the metadata sidebar so the chat takes the right pane.
  def handle_info({:workbench_companion, {:open, _spec}}, socket) do
    {:noreply, assign(socket, :companion_open, true)}
  end

  def handle_info({:workbench_companion, :close}, socket) do
    {:noreply, assign(socket, :companion_open, false)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp matches_current_file?(%{id: id}, socket), do: id == socket.assigns.file_id
  defp matches_current_file?(%{file_id: id}, socket), do: id == socket.assigns.file_id
  defp matches_current_file?(_, _), do: false

  defp file_pubsub_topic(%{workspace_id: nil, user_id: user_id}),
    do: "files:files:#{user_id}"

  defp file_pubsub_topic(%{workspace_id: ws_id}) when not is_nil(ws_id),
    do: "workspaces:#{ws_id}:files"

  # PdfPaneComponent's X button emits `close_pane` without phx-target, so it
  # bubbles to the parent LV. The file tab has its own close mechanism in the
  # workbench tab bar; absorb the event silently rather than crash.
  @impl true
  def handle_event("close_pane", _params, socket), do: {:noreply, socket}

  # Header "Open chat" button (role == "primary") — find-or-create the
  # companion conversation linked to this file and broadcast on the tab
  # topic so the workbench shell mounts a ConversationView companion. If
  # the companion is already open, the same click closes it.
  def handle_event("open_companion_chat", _params, socket) do
    user = socket.assigns.user
    file = socket.assigns.file
    tab_id = socket.assigns.tab_id

    cond do
      is_nil(user) or is_nil(file) or is_nil(tab_id) ->
        {:noreply, socket}

      socket.assigns.companion_open ->
        WorkbenchSignals.broadcast_close_companion(tab_id)
        {:noreply, socket}

      true ->
        case Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user) do
          {:ok, conv} ->
            WorkbenchSignals.broadcast_open_companion(tab_id, %{
              "type" => "conversation",
              "id" => conv.id
            })

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't open chat for this file.")}
        end
    end
  end

  # Header close button when this FileView is itself rendered as a
  # tab-bound companion (role == "companion"). Asks the workbench shell
  # to close us by broadcasting the standard close-companion signal.
  def handle_event("close_self_companion", _params, socket) do
    if tab_id = socket.assigns[:tab_id] do
      WorkbenchSignals.broadcast_close_companion(tab_id)
    end

    {:noreply, socket}
  end

  # PdfPaneComponent emits `pdf:ask_about_selection` (no phx-target) when
  # the user picks the "ask AI about this" action on a selection. Open
  # the file's companion conversation, drop the selection text into the
  # chat input, and forward the screenshot/page metadata via PubSub.
  #
  # NOTE: ConversationView currently stashes the broadcast `:pdf_selection`
  # payload in its assigns but does NOT yet attach it to the LLM context
  # on send (legacy chat-as-parent does that in chat_live.ex). Wiring the
  # send path to consume the stashed payload is a follow-up.
  def handle_event("pdf:ask_about_selection", payload, socket) do
    user = socket.assigns.user
    file = socket.assigns.file
    tab_id = socket.assigns.tab_id

    if is_nil(user) or is_nil(file) or is_nil(tab_id) do
      {:noreply, socket}
    else
      case Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user) do
        {:ok, conv} ->
          WorkbenchSignals.broadcast_open_companion(tab_id, %{
            "type" => "conversation",
            "id" => conv.id
          })

          text = (is_map(payload) && payload["text"]) || ""

          if is_binary(text) and text != "" do
            WorkbenchSignals.broadcast_insert_text(tab_id, text)
          end

          # Build the selection map shape expected downstream (atom keys),
          # including a server-derived filename so downstream readers do
          # not need a separate file lookup.
          selection_payload = %{
            text: if(is_binary(text), do: text, else: ""),
            image: is_map(payload) && payload["image"],
            page: is_map(payload) && payload["page"],
            filename: file.name
          }

          WorkbenchSignals.broadcast_pdf_selection(tab_id, selection_payload)

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't open chat for this file.")}
      end
    end
  end

  def handle_event("share_to_workspace", _params, socket) do
    # Guard against stale phx-click after the file was destroyed elsewhere:
    # mount/3 falls through to file: nil on lookup failure (the UI hides the
    # button), but a racing client click could still arrive. Treat as no-op.
    case socket.assigns.file do
      nil ->
        {:noreply, socket}

      file ->
        case Magus.Workspaces.grant_access(
               %{
                 resource_type: :file,
                 resource_id: file.id,
                 grantee_type: :workspace,
                 grantee_id: file.workspace_id,
                 role: :viewer
               },
               actor: socket.assigns.user
             ) do
          {:ok, _grant} ->
            {:noreply, refresh_file(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't share this file.")}
        end
    end
  end

  def handle_event("unshare_from_workspace", _params, socket) do
    # See share_to_workspace for why we guard on file: nil.
    case socket.assigns.file do
      nil ->
        {:noreply, socket}

      file ->
        user = socket.assigns.user

        with {:ok, grants} <-
               Magus.Workspaces.list_access_for_resource(:file, file.id, actor: user),
             %{} = grant <-
               Enum.find(grants, fn g ->
                 g.grantee_type == :workspace and g.grantee_id == file.workspace_id
               end) do
          # revoke_access (a destroy action) returns :ok or {:ok, _} depending
          # on how the code interface resolves it; tolerate either, treat
          # anything else as an error.
          case Magus.Workspaces.revoke_access(grant, actor: user) do
            :ok -> {:noreply, refresh_file(socket)}
            {:ok, _} -> {:noreply, refresh_file(socket)}
            {:error, _} -> {:noreply, put_flash(socket, :error, "Couldn't unshare this file.")}
          end
        else
          nil ->
            # No matching workspace grant — the calc said shared but there's
            # nothing to revoke. Treat as a no-op refresh so the UI catches up.
            {:noreply, refresh_file(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't unshare this file.")}
        end
    end
  end

  def handle_event("toggle_template", _params, socket) do
    case socket.assigns.file do
      nil ->
        {:noreply, socket}

      file ->
        case Magus.Files.update_file(
               file,
               %{is_template: !file.is_template},
               actor: socket.assigns.user
             ) do
          {:ok, _updated} ->
            {:noreply, refresh_file(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't update template flag.")}
        end
    end
  end

  def handle_event("delete", _params, socket) do
    # See share_to_workspace for why we guard on file: nil.
    case socket.assigns.file do
      nil ->
        {:noreply, socket}

      file ->
        case Magus.Files.delete_file(file, actor: socket.assigns.user) do
          :ok ->
            {:noreply, push_navigate(socket, to: "/chat")}

          {:ok, _} ->
            # Some destroy actions return {:ok, record}; tolerate either shape.
            {:noreply, push_navigate(socket, to: "/chat")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Couldn't delete this file.")}
        end
    end
  end

  defp refresh_file(socket) do
    case Magus.Files.get_file(socket.assigns.file_id,
           actor: socket.assigns.user,
           load: [:knowledge_collection, :folder, :is_shared_to_workspace]
         ) do
      {:ok, file} -> assign(socket, :file, file)
      _ -> socket
    end
  end

  @impl true
  def terminate(_reason, socket) do
    case Map.get(socket.assigns, :file) do
      nil -> :ok
      file -> Magus.Endpoint.unsubscribe(file_pubsub_topic(file))
    end
  end

  @impl true
  def render(%{file: nil} = assigns) do
    ~H"""
    <div
      data-file-view
      data-tab-id={@tab_id}
      class="h-full flex items-center justify-center text-wb-text-dim"
    >
      <p>File not found.</p>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      data-file-view
      data-file-id={@file.id}
      data-tab-id={@tab_id}
      class="h-full flex flex-col"
    >
      <div class="h-10 flex items-center justify-between md:px-3 px-14 border-b border-wb-border">
        <div class="text-sm font-medium truncate">{@file.name}</div>
        <div class="flex items-center gap-1">
          <button
            :if={@role == "primary"}
            type="button"
            data-file-open-chat
            phx-click="open_companion_chat"
            class={["wb-pill-btn", @companion_open && "wb-pill-btn-active"]}
            title={if @companion_open, do: "Close chat", else: "Open chat about this file"}
          >
            <.icon name="lucide-message-square" class="w-4 h-4" />
            <span>{if @companion_open, do: "Close chat", else: "Open chat"}</span>
          </button>
          <button
            :if={@role == "companion"}
            type="button"
            phx-click="close_self_companion"
            class="wb-pill-btn wb-pill-btn-square"
            title="Close"
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 flex">
        <div class="flex-1 min-w-0 overflow-auto">
          <.viewer file={@file} user={@user} download_url={@download_url} tab_id={@tab_id} />
        </div>
        <aside
          :if={not @companion_open}
          class="w-72 border-l border-wb-border bg-wb-surface p-4 overflow-auto"
          aria-label="File details"
        >
          <.meta_sidebar file={@file} download_url={@download_url} />
        </aside>
      </div>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :download_url, :string, required: true

  defp meta_sidebar(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div>
        <h2 class="text-sm font-semibold text-wb-text">{@file.name}</h2>
        <p class="text-xs text-wb-text-dim">{format_status(@file.status)}</p>
      </div>
      <dl class="grid grid-cols-1 gap-2 text-xs">
        <.meta_row label="Size">{format_bytes(@file.file_size)}</.meta_row>
        <.meta_row label="Type">{@file.mime_type || "—"}</.meta_row>
        <.meta_row label="Source">{format_source(@file)}</.meta_row>
        <.meta_row label="Created">{format_dt(@file.inserted_at)}</.meta_row>
        <.meta_row label="Updated">{format_dt(@file.updated_at)}</.meta_row>
      </dl>
      <a
        href={@download_url}
        download
        data-action="download"
        class="px-3 py-1.5 text-xs rounded-md border border-wb-border text-center hover:bg-wb-hover"
      >
        Download
      </a>
      <label class="flex items-center gap-2 text-xs text-wb-text-secondary">
        <input
          type="checkbox"
          checked={@file.is_template}
          phx-click="toggle_template"
          phx-value-id={@file.id}
          data-role={"toggle-template-#{@file.id}"}
          class="checkbox checkbox-xs"
        />
        {gettext("Use as template")}
      </label>
      <button
        :if={@file.workspace_id && not @file.is_shared_to_workspace}
        type="button"
        data-action="share-to-workspace"
        phx-click="share_to_workspace"
        class="px-3 py-1.5 text-xs rounded-md bg-wb-accent text-white hover:opacity-90"
      >
        Share with workspace
      </button>
      <button
        :if={@file.workspace_id && @file.is_shared_to_workspace}
        type="button"
        data-action="unshare-from-workspace"
        phx-click="unshare_from_workspace"
        class="px-3 py-1.5 text-xs rounded-md border border-wb-border hover:bg-wb-hover"
      >
        Unshare from workspace
      </button>
      <button
        type="button"
        data-action="delete"
        phx-click="delete"
        data-confirm="Delete this file?"
        class="px-3 py-1.5 text-xs rounded-md border border-error text-error hover:bg-error/10"
      >
        Delete
      </button>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :user, :map, required: true
  attr :download_url, :string, required: true
  attr :tab_id, :string, default: nil

  defp viewer(assigns) do
    cond do
      assigns.file.type == :image ->
        ~H"""
        <div data-viewer="image" class="h-full flex items-center justify-center bg-wb-bg p-4">
          <img src={@download_url} alt={@file.name} class="max-h-full max-w-full object-contain" />
        </div>
        """

      assigns.file.mime_type == "application/pdf" ->
        ~H"""
        <div data-viewer="pdf" class="h-full">
          <.live_component
            module={MagusWeb.ChatLive.Components.Pdf.PdfPaneComponent}
            id={"pdf-#{@file.id}"}
            pdf={%{file: %{id: @file.id, name: @file.name}, url: @download_url}}
            page_count={nil}
            zoom_percent={100}
          />
        </div>
        """

      xlsx_file?(assigns.file) ->
        ~H"""
        <div data-viewer="spreadsheet" class="h-full">
          {live_render(@socket, MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanion,
            id: "spreadsheet-primary-#{@file.id}",
            session: %{
              "file_id" => @file.id,
              "user_id" => @user.id,
              "tab_id" => @tab_id
            }
          )}
        </div>
        """

      assigns.file.type == :video ->
        ~H"""
        <div data-viewer="video" class="h-full flex items-center justify-center bg-black">
          <video controls class="max-h-full max-w-full" src={@download_url}></video>
        </div>
        """

      assigns.file.type in [:text, :email] ->
        assigns = assign(assigns, :body, read_storage_body(assigns.file))

        ~H"""
        <div data-viewer="text" class="h-full overflow-auto p-6 prose prose-sm max-w-none">
          <pre class="whitespace-pre-wrap break-words">{@body}</pre>
        </div>
        """

      assigns.file.type == :document ->
        case document_text(assigns.file, assigns) do
          nil ->
            generic_viewer(assigns)

          "" ->
            generic_viewer(assigns)

          text ->
            assigns = assign(assigns, :body, text)

            ~H"""
            <div data-viewer="document" class="h-full overflow-auto p-6 prose prose-sm max-w-none">
              <pre class="whitespace-pre-wrap break-words">{@body}</pre>
            </div>
            """
        end

      true ->
        generic_viewer(assigns)
    end
  end

  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp xlsx_file?(%{mime_type: @xlsx_mime}), do: true

  defp xlsx_file?(%{name: name}) when is_binary(name),
    do: String.ends_with?(String.downcase(name), ".xlsx")

  defp xlsx_file?(_), do: false

  defp read_storage_body(%{file_path: nil}), do: "(no file content)"

  defp read_storage_body(%{file_path: path}) do
    # Caller is expected to have already authorized read on the file (mount/3
    # gates that). The UTF-8 check guards against binary or non-UTF-8 content
    # that would otherwise crash HEEx rendering.
    case Files.Storage.get(path) do
      {:ok, body} ->
        if String.valid?(body), do: body, else: "(binary content; download to view)"

      _ ->
        "(could not load file content)"
    end
  end

  defp document_text(%{id: id, status: :ready}, %{user: user}) do
    case Files.get_chunks_for_file(id, actor: user) do
      {:ok, []} ->
        nil

      {:ok, chunks} ->
        chunks
        |> Enum.sort_by(& &1.position)
        |> Enum.map_join("\n\n", & &1.content)

      _ ->
        nil
    end
  end

  defp document_text(_, _), do: nil

  defp generic_viewer(assigns) do
    ~H"""
    <div
      data-viewer="generic"
      class="h-full flex flex-col items-center justify-center gap-4 text-wb-text-muted p-8"
    >
      <.icon name="lucide-file" class="w-16 h-16" />
      <p class="text-sm">{@file.name}</p>
      <a
        href={@download_url}
        download
        class="px-4 py-2 text-sm rounded-md bg-wb-accent text-white"
      >
        Download
      </a>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp meta_row(assigns) do
    ~H"""
    <div class="flex justify-between gap-2">
      <dt class="text-wb-text-dim">{@label}</dt>
      <dd class="text-wb-text text-right truncate">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp format_status(:ready), do: "Ready"
  defp format_status(:processing), do: "Indexing…"
  defp format_status(:pending), do: "Pending"
  defp format_status(:error), do: "Error"
  defp format_status(other), do: to_string(other)

  defp format_bytes(nil), do: "—"
  defp format_bytes(b) when b < 1024, do: "#{b} B"
  defp format_bytes(b) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_bytes(b), do: "#{Float.round(b / (1024 * 1024), 1)} MB"

  defp format_source(%{source: :connector, knowledge_collection: %{name: n}}) when is_binary(n),
    do: "Synced from #{n}"

  defp format_source(%{source: :connector}), do: "Synced (connector)"
  defp format_source(%{source: :user}), do: "User upload"
  defp format_source(%{source: :agent}), do: "Generated by agent"
  defp format_source(_), do: "—"

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(other), do: to_string(other)

  defp download_url(nil), do: "#"

  defp download_url(file_path) do
    case Files.Storage.get_url(file_path) do
      {:ok, url} -> url
      _ -> "#"
    end
  end
end
