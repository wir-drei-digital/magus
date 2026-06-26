defmodule MagusWeb.Workbench.Resources.FileBrowserView do
  @moduledoc """
  Main-area LiveView for the file browser. URL is the source of truth for
  scope/filters/sort/q; per-user view mode lives on `user.ui_preferences`.
  Renders top bar + grid or list.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Workbench.Resources.FileBrowserView.{
    ContextMenu,
    Data,
    Events,
    FolderPickerModal,
    Grid,
    List,
    RenameModal,
    TopBar
  }

  alias MagusWeb.Workbench.UploadHelpers
  alias MagusWeb.Workbench.Signals

  @impl true
  def mount(_params, session, socket) do
    user = Magus.Accounts.get_user!(session["user_id"], authorize?: false)

    if connected?(socket) do
      Magus.Endpoint.subscribe("files:files:#{user.id}")

      if ws = session["workspace_id"],
        do: Magus.Endpoint.subscribe("workspaces:#{ws}:files")

      if tab_id = session["tab_id"],
        do: Phoenix.PubSub.subscribe(Magus.PubSub, Signals.tab_topic(tab_id))
    end

    view_mode =
      case Map.get(user.ui_preferences || %{}, "file_browser_view") do
        "list" -> "list"
        _ -> "grid"
      end

    socket =
      socket
      |> assign(:user, user)
      |> assign(:current_user, user)
      |> assign(:tab_id, session["tab_id"])
      |> assign(:workspace_id, session["workspace_id"])
      |> assign(:scope, session["scope"] || "my_files")
      |> assign(:scope_id, session["id"])
      |> assign(:filters, session["filters"] || %{})
      |> assign(:sort, session["sort"] || "updated_at:desc")
      |> assign(:q, session["q"] || "")
      |> assign(:view_mode, view_mode)
      |> assign(:menu_for, nil)
      |> assign(:rename_target, nil)
      |> assign(:move_target, nil)
      |> assign(:new_folder_open?, false)
      |> assign(:reload_pending?, false)
      |> assign(:total_before_cap, 0)
      |> assign(:entries_empty?, true)
      |> stream(:entries, [])
      |> assign(:breadcrumbs, [])
      |> assign_upload_context()
      |> UploadHelpers.allow_uploads(:files,
        auto_upload: true,
        progress: &handle_upload_progress/3
      )
      # The entry listing (capped at 500) is the heavy read; defer it to the
      # connected mount so the disconnected (static) render stays query-free.
      # The stream/breadcrumb/empty defaults above render the skeleton.
      |> then(fn socket ->
        if connected?(socket), do: reload_entries(socket), else: socket
      end)

    {:ok, socket}
  end

  @impl true
  def handle_info({:browser_params_changed, params}, socket) do
    socket =
      socket
      |> assign(:scope, params.scope)
      |> assign(:scope_id, params.id)
      |> assign(:filters, params.filters || %{})
      |> assign(:sort, params.sort || "updated_at:desc")
      |> assign(:q, params.q || "")
      |> assign_upload_context()
      |> reload_entries()

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "files:files:" <> _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "workspaces:" <> _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_now, socket) do
    {:noreply,
     socket
     |> assign(:reload_pending?, false)
     |> reload_entries()}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "tab:" <> _, event: event} = msg, socket) do
    require Logger

    Logger.debug(
      "FileBrowserView ignoring unhandled tab broadcast: #{event} #{inspect(msg.payload)}"
    )

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("search_input", %{"q" => q}, socket) do
    {:noreply, broadcast_patch(socket, %{"q" => q})}
  end

  def handle_event("set_sort", %{"sort" => sort}, socket) do
    {:noreply, broadcast_patch(socket, %{"sort" => sort})}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, broadcast_patch(socket, %{"type" => nil, "modified" => nil, "source" => nil})}
  end

  def handle_event("open_entry", %{"kind" => "folder"} = params, socket),
    do: Events.open_folder_entry(socket, params)

  def handle_event("open_entry", %{"kind" => "file"} = params, socket),
    do: Events.open_file_entry(socket, params)

  def handle_event("navigate_breadcrumb", params, socket),
    do: Events.navigate_breadcrumb(socket, params)

  def handle_event("open_menu", %{"kind" => kind, "id" => id, "x" => x, "y" => y}, socket) do
    {:noreply, assign(socket, :menu_for, %{kind: kind, id: id, x: x, y: y})}
  end

  def handle_event("close_menu", _params, socket), do: {:noreply, assign(socket, :menu_for, nil)}

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["list", "grid"] do
    user = socket.assigns.user
    prefs = Map.put(user.ui_preferences || %{}, "file_browser_view", mode)

    case Magus.Accounts.update_ui_preferences(user, prefs, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:user, updated_user)
         |> assign(:view_mode, mode)
         |> reload_entries()}

      {:error, error} ->
        require Logger
        Logger.warning("file_browser: failed to persist view_mode=#{mode}: #{inspect(error)}")
        {:noreply, socket |> assign(:view_mode, mode) |> reload_entries()}
    end
  end

  def handle_event("rename_entry", params, socket), do: Events.rename_entry(socket, params)

  def handle_event("submit_rename", params, socket),
    do: Events.submit_rename(socket, params, &reload_entries/1)

  def handle_event("toggle_template_entry", params, socket),
    do: Events.toggle_template_entry(socket, params, &reload_entries/1)

  def handle_event("share_entry", params, socket),
    do: Events.share_entry(socket, params, &reload_entries/1)

  def handle_event("trash_entry", params, socket),
    do: Events.trash_entry(socket, params, &reload_entries/1)

  def handle_event("download_entry", params, socket), do: Events.download_entry(socket, params)

  def handle_event("open_entry_chat", params, socket),
    do: Events.open_entry_chat(socket, params)

  def handle_event("move_entry", params, socket), do: Events.move_entry(socket, params)

  def handle_event("cancel_move", params, socket), do: Events.cancel_move(socket, params)

  def handle_event("cancel_rename", params, socket), do: Events.cancel_rename(socket, params)

  def handle_event("confirm_move", params, socket),
    do: Events.confirm_move(socket, params, &reload_entries/1)

  def handle_event("start_new_folder", _params, socket) do
    if socket.assigns.scope in ["my_files", "folder", "shared"] do
      {:noreply, assign(socket, :new_folder_open?, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_new_folder", _params, socket),
    do: {:noreply, assign(socket, :new_folder_open?, false)}

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, Phoenix.LiveView.cancel_upload(socket, :files, ref)}
  end

  def handle_event("submit_new_folder", %{"name" => name}, socket) do
    user = socket.assigns.user
    trimmed = String.trim(name || "")

    if trimmed == "" do
      {:noreply, assign(socket, :new_folder_open?, false)}
    else
      parent_id =
        if socket.assigns.scope == "folder", do: socket.assigns.scope_id, else: nil

      attrs = %{
        name: trimmed,
        parent_id: parent_id,
        workspace_id: socket.assigns.workspace_id,
        kind: :files
      }

      case Magus.Chat.create_folder(attrs, actor: user) do
        {:ok, _folder} ->
          {:noreply, socket |> assign(:new_folder_open?, false) |> reload_entries()}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(:new_folder_open?, false)
           |> put_flash(:error, gettext("Could not create folder."))}
      end
    end
  end

  defp broadcast_patch(socket, overrides) do
    payload = %{
      tab_id: socket.assigns.tab_id,
      scope: socket.assigns.scope,
      scope_id: socket.assigns.scope_id,
      overrides: overrides
    }

    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      Signals.workbench_user_topic(socket.assigns.user.id),
      {:file_browser_patch, payload}
    )

    socket
  end

  defp schedule_reload(socket) do
    if socket.assigns.reload_pending? do
      socket
    else
      Process.send_after(self(), :reload_now, 150)
      assign(socket, :reload_pending?, true)
    end
  end

  # auto_upload: when every entry has finished streaming to the server, consume
  # them and create File records. This avoids a separate "submit" click.
  defp handle_upload_progress(:files, entry, socket) do
    if entry.done? do
      pending? =
        Enum.any?(socket.assigns.uploads.files.entries, fn e ->
          e.ref != entry.ref and not e.done?
        end)

      if pending? do
        {:noreply, socket}
      else
        user = socket.assigns.user

        files =
          Enum.map(socket.assigns.uploads.files.entries, fn e ->
            %{name: e.client_name, size: e.client_size}
          end)

        case Magus.Usage.PolicyEnforcer.check_file_uploads(user, files) do
          {:ok, :allowed} ->
            UploadHelpers.do_upload(socket,
              upload_name: :files,
              reload_fun: &reload_entries/1
            )

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
      end
    else
      {:noreply, socket}
    end
  end

  # Sets the assigns that `MagusWeb.Workbench.UploadHelpers.do_upload/2`
  # consults: `:current_user`, `:file_scope`, `:folder_id`, `:conversation_id`.
  # The browser doesn't have a conversation context, so we always nil it out.
  defp assign_upload_context(socket) do
    {file_scope, folder_id} =
      case socket.assigns.scope do
        "folder" -> {:folder, socket.assigns.scope_id}
        "shared" -> {:workspace, nil}
        _ -> {:global, nil}
      end

    socket
    |> assign(:file_scope, file_scope)
    |> assign(:folder_id, folder_id)
    |> assign(:conversation_id, nil)
  end

  defp reload_entries(socket) do
    %{entries: entries, breadcrumbs: bc, total_before_cap: total} =
      Data.load(%{
        scope: socket.assigns.scope,
        id: socket.assigns.scope_id,
        user: socket.assigns.user,
        workspace_id: socket.assigns.workspace_id,
        filters: socket.assigns.filters,
        sort: socket.assigns.sort,
        q: socket.assigns.q
      })

    socket
    |> stream(:entries, entries, reset: true)
    |> assign(:breadcrumbs, bc)
    |> assign(:total_before_cap, total)
    |> assign(:entries_empty?, entries == [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="file-browser h-full flex flex-col" data-file-browser data-tab-id={@tab_id}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".OpenUrl">
        export default {
          mounted() {
            this.handleEvent("open-url", ({ url }) => window.open(url, "_blank", "noopener"));
          }
        }
      </script>
      <div phx-hook=".OpenUrl" id={"file-browser-open-url-#{@tab_id}"} class="hidden"></div>

      <.live_component
        module={TopBar}
        id={"file-browser-topbar-#{@tab_id}"}
        breadcrumbs={@breadcrumbs}
        q={@q}
        sort={@sort}
        view_mode={@view_mode}
        scope={@scope}
        scope_id={@scope_id}
        upload_config={@uploads}
      />

      <div
        :if={cap_banner?(@total_before_cap)}
        class="px-4 py-2 text-xs bg-warning/10 text-warning border-b border-wb-border"
      >
        {gettext("Showing 500 of %{total}, narrow with filters or search.",
          total: @total_before_cap
        )}
      </div>

      <div
        :if={active_filters?(@filters)}
        class="px-4 py-2 text-xs text-wb-text-dim border-b border-wb-border"
      >
        {render_active_filters(@filters)}
        <button type="button" phx-click="clear_filters" class="ml-2 underline">
          {gettext("Clear")}
        </button>
      </div>

      <div class="flex-1 min-h-0 overflow-auto">
        <%= if @view_mode == "list" do %>
          <.live_component
            module={List}
            id={"file-browser-list-#{@tab_id}"}
            entries_stream={@streams.entries}
            entries_empty?={@entries_empty?}
            sort={@sort}
            scope={@scope}
            new_folder_open?={@new_folder_open?}
          />
        <% else %>
          <.live_component
            module={Grid}
            id={"file-browser-grid-#{@tab_id}"}
            entries_stream={@streams.entries}
            entries_empty?={@entries_empty?}
            scope={@scope}
            new_folder_open?={@new_folder_open?}
          />
        <% end %>
      </div>

      <.live_component
        :if={@menu_for}
        module={ContextMenu}
        id={"file-browser-menu-#{@tab_id}"}
        menu_for={@menu_for}
        scope={@scope}
      />

      <.live_component
        :if={@move_target}
        module={FolderPickerModal}
        id={"file-browser-move-#{@tab_id}"}
        user={@user}
        workspace_id={@workspace_id}
        move_target={@move_target}
      />

      <.live_component
        :if={@rename_target}
        module={RenameModal}
        id={"file-browser-rename-#{@tab_id}"}
        user={@user}
        rename_target={@rename_target}
      />
    </div>
    """
  end

  defp cap_banner?(total), do: total > 500

  defp active_filters?(%{} = f),
    do: Enum.any?([f["type"], f["modified"], f["source"]], &(&1 not in [nil, "", "any"]))

  defp render_active_filters(%{} = f) do
    [
      f["type"] && "#{gettext("Type:")} #{String.capitalize(f["type"])}",
      f["modified"] && "#{gettext("Modified:")} #{format_modified(f["modified"])}",
      f["source"] && "#{gettext("Source:")} #{format_source(f["source"])}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp format_modified("today"), do: gettext("Today")
  defp format_modified("this_week"), do: gettext("This week")
  defp format_modified("this_month"), do: gettext("This month")
  defp format_modified("this_year"), do: gettext("This year")
  defp format_modified("older"), do: gettext("Older")
  defp format_modified(other), do: other

  defp format_source("uploaded"), do: gettext("Upload")
  defp format_source("agent"), do: gettext("Generated")
  defp format_source("synced"), do: gettext("Synced")
  defp format_source(other), do: other
end
