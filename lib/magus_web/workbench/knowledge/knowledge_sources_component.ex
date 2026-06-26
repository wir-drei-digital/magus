defmodule MagusWeb.Knowledge.KnowledgeSourcesComponent do
  @moduledoc """
  LiveComponent that displays expandable knowledge source cards with their collections.

  Supports personal and workspace scopes. Each source card expands to show
  its collections with sync status, actions, and error details.
  """

  use MagusWeb, :live_component

  import MagusWeb.Knowledge.Components.KnowledgeSourceCard

  require Ash.Query

  alias Magus.Knowledge

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       sources: [],
       collections_by_source: %{},
       expanded: MapSet.new(),
       show_wizard: false,
       wizard_existing_source: nil,
       loaded: false,
       show_log_for: nil,
       storage_by_collection: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if assigns[:refresh] do
        load_sources(socket)
      else
        socket
      end

    socket =
      if assigns[:wizard_complete] do
        expanded =
          if assigns[:expand_source_id] do
            MapSet.put(socket.assigns.expanded, assigns[:expand_source_id])
          else
            socket.assigns.expanded
          end

        socket |> assign(show_wizard: false, expanded: expanded) |> load_sources()
      else
        socket
      end

    socket =
      if assigns[:close_wizard] do
        assign(socket, show_wizard: false)
      else
        socket
      end

    socket =
      if assigns[:resume_wizard_provider] && !socket.assigns[:wizard_resumed] do
        socket
        |> assign(show_wizard: true, wizard_resumed: true)
      else
        socket
      end

    socket =
      if not socket.assigns.loaded do
        socket
        |> load_sources()
        |> assign(:loaded, true)
      else
        socket
      end

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-lg font-medium">{gettext("Connected Sources")}</h2>
          <p class="text-base-content/60 text-sm mt-1">
            {gettext("Sync data from external services")}
          </p>
        </div>
        <button
          class="btn btn-primary btn-sm"
          phx-click="show_connect_wizard"
          phx-target={@myself}
        >
          <.icon name="lucide-plus" class="size-4" />
          {gettext("Connect New")}
        </button>
      </div>

      <%= if Enum.empty?(@sources) do %>
        <div class="text-center py-12">
          <.icon name="lucide-folder-sync" class="size-12 mx-auto text-base-content/20 mb-4" />
          <p class="text-base-content/50 text-sm">
            {gettext("No sync sources connected yet")}
          </p>
          <button
            class="btn btn-primary btn-sm mt-4"
            phx-click="show_connect_wizard"
            phx-target={@myself}
          >
            {gettext("Connect your first source")}
          </button>
        </div>
      <% else %>
        <div class="space-y-3">
          <div :for={source <- @sources} class="card bg-base-100 shadow-sm border border-base-300">
            <div
              class="card-body p-4 cursor-pointer"
              phx-click="toggle_source"
              phx-value-id={source.id}
              phx-target={@myself}
            >
              <div class="flex items-center gap-3">
                <.provider_icon provider={source.provider} size={:md} />
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2">
                    <h3 class="font-medium truncate">{source.name}</h3>
                    <.sync_status_badge status={source.status} />
                  </div>
                  <p class="text-xs text-base-content/50 mt-0.5">
                    {collection_count_text(Map.get(@collections_by_source, source.id, []))}
                    <span class="mx-1">&middot;</span>
                    {format_bytes(
                      source_storage(source.id, @collections_by_source, @storage_by_collection)
                    )}
                  </p>
                </div>
                <.icon
                  name={
                    if MapSet.member?(@expanded, source.id),
                      do: "lucide-chevron-up",
                      else: "lucide-chevron-down"
                  }
                  class="size-4 text-base-content/40"
                />
              </div>
            </div>

            <div
              :if={MapSet.member?(@expanded, source.id)}
              class="border-t border-base-300 px-4 pb-4"
            >
              <div
                :if={source.last_error}
                class="alert alert-error alert-sm mt-3 text-sm"
              >
                <.icon name="lucide-alert-circle" class="size-4" />
                <span>{source.last_error}</span>
              </div>

              <div class="flex items-center justify-between mt-4 mb-2">
                <span class="text-xs text-base-content/50 uppercase tracking-wider font-medium">
                  {gettext("Collections")}
                </span>
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="add_collection_to_source"
                  phx-value-id={source.id}
                  phx-target={@myself}
                >
                  <.icon name="lucide-plus" class="size-3" />
                  {gettext("Add")}
                </button>
              </div>

              <%= if Enum.empty?(Map.get(@collections_by_source, source.id, [])) do %>
                <p class="text-sm text-base-content/40 py-3 text-center">
                  {gettext("No collections yet")}
                </p>
              <% else %>
                <div class="space-y-1">
                  <div :for={collection <- Map.get(@collections_by_source, source.id, [])}>
                    <div class="group flex items-center gap-3 rounded-lg p-2 hover:bg-base-200/50">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="text-sm font-medium truncate">{collection.name}</span>
                          <.sync_status_badge status={collection.sync_status} />
                        </div>
                        <div class="flex items-center gap-3 text-xs text-base-content/50 mt-0.5">
                          <span :if={collection.external_path} class="truncate max-w-48">
                            {collection.external_path}
                          </span>
                          <span>
                            {ngettext("%{count} file", "%{count} files", collection.item_count || 0)}
                          </span>
                          <span>
                            {format_bytes(Map.get(@storage_by_collection, collection.id, 0))}
                          </span>
                          <span :if={collection.last_synced_at}>
                            {relative_time(collection.last_synced_at)}
                          </span>
                          <span
                            :if={(collection.error_count || 0) > 0}
                            class="text-error"
                          >
                            {ngettext(
                              "%{count} error",
                              "%{count} errors",
                              collection.error_count
                            )}
                          </span>
                        </div>
                      </div>
                      <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100">
                        <button
                          class="btn btn-ghost btn-xs"
                          title={gettext("Sync Log")}
                          phx-click="toggle_sync_log"
                          phx-value-id={collection.id}
                          phx-target={@myself}
                        >
                          <.icon name="lucide-file-text" class="size-3" />
                        </button>
                        <button
                          class="btn btn-ghost btn-xs"
                          title={gettext("Re-sync")}
                          phx-click="resync_collection"
                          phx-value-id={collection.id}
                          phx-value-source-id={source.id}
                          phx-target={@myself}
                          disabled={collection.sync_status == :syncing}
                        >
                          <.icon name="lucide-refresh-cw" class="size-3" />
                        </button>
                        <button
                          class="btn btn-ghost btn-xs text-error"
                          title={gettext("Remove")}
                          phx-click="remove_collection"
                          phx-value-id={collection.id}
                          phx-value-source-id={source.id}
                          phx-target={@myself}
                          data-confirm={gettext("Are you sure you want to remove this collection?")}
                        >
                          <.icon name="lucide-trash-2" class="size-3" />
                        </button>
                      </div>
                    </div>
                    <div
                      :if={@show_log_for == collection.id or collection.sync_status == :syncing}
                      class="mx-2 mb-2 rounded-lg bg-base-200 border border-base-300 overflow-hidden"
                    >
                      <div class="flex items-center justify-between px-3 py-1.5 border-b border-base-300">
                        <span class="text-xs font-medium text-base-content/60">
                          {gettext("Sync Log")}
                        </span>
                        <button
                          class="btn btn-ghost btn-xs"
                          phx-click="toggle_sync_log"
                          phx-value-id={collection.id}
                          phx-target={@myself}
                        >
                          <.icon name="lucide-x" class="size-3" />
                        </button>
                      </div>
                      <div
                        class="max-h-48 overflow-y-auto p-2 font-mono text-xs space-y-0.5"
                        id={"sync-log-#{collection.id}"}
                      >
                        <%= for entry <- get_log_entries(collection) do %>
                          <div class={["flex gap-2", log_entry_class(entry)]}>
                            <span class="text-base-content/40 shrink-0">
                              {format_log_time(entry)}
                            </span>
                            <span class={log_level_class(entry)}>{entry["l"] || entry[:l]}</span>
                            <span class="break-all">{entry["m"] || entry[:m]}</span>
                          </div>
                        <% end %>
                        <div
                          :if={Enum.empty?(get_log_entries(collection))}
                          class="text-base-content/40 text-center py-2"
                        >
                          {gettext("No log entries yet")}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>

              <div class="mt-4 pt-3 border-t border-base-300">
                <button
                  class="btn btn-ghost btn-sm text-error"
                  phx-click="disconnect_source"
                  phx-value-id={source.id}
                  phx-target={@myself}
                  data-confirm={gettext("Disconnect this source? All collections will be removed.")}
                >
                  <.icon name="lucide-unplug" class="size-4" />
                  {gettext("Disconnect")}
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <.live_component
        :if={@show_wizard}
        module={MagusWeb.Knowledge.Components.ConnectSourceWizard}
        id="connect-wizard"
        current_user={@current_user}
        scope={@scope}
        wizard_existing_source={@wizard_existing_source}
        oauth_tokens={assigns[:oauth_tokens]}
        resume_wizard_provider={assigns[:resume_wizard_provider]}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_source", %{"id" => source_id}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, source_id) do
        MapSet.delete(expanded, source_id)
      else
        MapSet.put(expanded, source_id)
      end

    # Load collections for newly expanded source if not already loaded
    socket =
      if MapSet.member?(expanded, source_id) and
           not Map.has_key?(socket.assigns.collections_by_source, source_id) do
        load_collections_for_source(socket, source_id)
      else
        socket
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("toggle_sync_log", %{"id" => collection_id}, socket) do
    show_log_for =
      if socket.assigns.show_log_for == collection_id, do: nil, else: collection_id

    {:noreply, assign(socket, :show_log_for, show_log_for)}
  end

  def handle_event("show_connect_wizard", _params, socket) do
    {:noreply, assign(socket, show_wizard: true, wizard_existing_source: nil)}
  end

  def handle_event("add_collection_to_source", %{"id" => source_id}, socket) do
    source = Enum.find(socket.assigns.sources, &(&1.id == source_id))

    if source do
      {:noreply, assign(socket, show_wizard: true, wizard_existing_source: source)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_wizard", _params, socket) do
    {:noreply, assign(socket, show_wizard: false, wizard_existing_source: nil)}
  end

  def handle_event(
        "resync_collection",
        %{"id" => collection_id, "source-id" => source_id},
        socket
      ) do
    case Knowledge.get_collection(collection_id, actor: socket.assigns.current_user) do
      {:ok, %{sync_status: :syncing}} ->
        {:noreply, socket}

      {:ok, collection} ->
        Knowledge.trigger_full_sync(collection, actor: socket.assigns.current_user)
        {:noreply, load_collections_for_source(socket, source_id)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "remove_collection",
        %{"id" => collection_id, "source-id" => source_id},
        socket
      ) do
    case Knowledge.get_collection(collection_id, actor: socket.assigns.current_user) do
      {:ok, collection} ->
        case Knowledge.destroy_collection(collection, actor: socket.assigns.current_user) do
          :ok ->
            socket = load_collections_for_source(socket, source_id)
            {:noreply, Phoenix.LiveView.put_flash(socket, :info, gettext("Collection removed"))}

          {:error, _} ->
            {:noreply,
             Phoenix.LiveView.put_flash(socket, :error, gettext("Failed to remove collection"))}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("disconnect_source", %{"id" => source_id}, socket) do
    source = Enum.find(socket.assigns.sources, &(&1.id == source_id))

    if source do
      case Knowledge.destroy_source(source, actor: socket.assigns.current_user) do
        :ok ->
          socket = load_sources(socket)
          {:noreply, Phoenix.LiveView.put_flash(socket, :info, gettext("Source disconnected"))}

        {:error, _} ->
          {:noreply,
           Phoenix.LiveView.put_flash(socket, :error, gettext("Failed to disconnect source"))}
      end
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Data Loading
  # ---------------------------------------------------------------------------

  defp load_sources(socket) do
    sources =
      case socket.assigns.scope do
        :personal ->
          case Knowledge.list_sources_for_user(actor: socket.assigns.current_user) do
            {:ok, sources} -> sources
            _ -> []
          end

        {:workspace, workspace_id} ->
          case Knowledge.list_sources_for_workspace(workspace_id,
                 actor: socket.assigns.current_user
               ) do
            {:ok, sources} -> sources
            _ -> []
          end
      end

    # Load collections for all sources (needed for collection counts on collapsed cards)
    collections_by_source =
      Enum.reduce(sources, %{}, fn source, acc ->
        case Knowledge.list_collections_for_source(source.id, actor: socket.assigns.current_user) do
          {:ok, collections} -> Map.put(acc, source.id, collections)
          _ -> acc
        end
      end)

    # Notify parent LiveView so it can subscribe to PubSub topics
    send(self(), {:subscribe_knowledge_sources, Enum.map(sources, & &1.id)})

    all_collection_ids =
      collections_by_source
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    # Calculate storage per collection
    storage_by_collection = calculate_storage(all_collection_ids, socket.assigns.current_user)

    assign(socket,
      sources: sources,
      collections_by_source: collections_by_source,
      storage_by_collection: storage_by_collection
    )
  end

  defp load_collections_for_source(socket, source_id) do
    case Knowledge.list_collections_for_source(source_id, actor: socket.assigns.current_user) do
      {:ok, collections} ->
        collections_by_source =
          Map.put(socket.assigns.collections_by_source, source_id, collections)

        assign(socket, :collections_by_source, collections_by_source)

      _ ->
        socket
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collection_count_text(collections) do
    count = length(collections)
    ngettext("%{count} collection", "%{count} collections", count)
  end

  defp relative_time(nil), do: ""

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> gettext("just now")
      diff_seconds < 3600 -> gettext("%{count}m ago", count: div(diff_seconds, 60))
      diff_seconds < 86400 -> gettext("%{count}h ago", count: div(diff_seconds, 3600))
      true -> gettext("%{count}d ago", count: div(diff_seconds, 86400))
    end
  end

  defp get_log_entries(collection) do
    collection.sync_log || []
  end

  defp format_log_time(entry) do
    raw = entry["t"] || entry[:t] || ""

    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> ""
    end
  end

  defp log_entry_class(entry) do
    case entry["l"] || entry[:l] do
      "error" -> "text-error"
      "warn" -> "text-warning"
      _ -> ""
    end
  end

  defp log_level_class(entry) do
    case entry["l"] || entry[:l] do
      "error" -> "text-error font-semibold"
      "warn" -> "text-warning font-semibold"
      "info" -> "text-info"
      _ -> "text-base-content/60"
    end
  end

  defp calculate_storage(collection_ids, _actor) when collection_ids == [], do: %{}

  defp calculate_storage(collection_ids, actor) do
    Magus.Files.File
    |> Ash.Query.filter(
      knowledge_collection_id in ^collection_ids and
        is_nil(deleted_at)
    )
    |> Ash.Query.select([:knowledge_collection_id, :file_size])
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.knowledge_collection_id)
    |> Map.new(fn {cid, files} ->
      {cid, files |> Enum.map(& &1.file_size) |> Enum.reject(&is_nil/1) |> Enum.sum()}
    end)
  end

  defp source_storage(source_id, collections_by_source, storage_by_collection) do
    collections = Map.get(collections_by_source, source_id, [])

    Enum.reduce(collections, 0, fn c, acc ->
      acc + Map.get(storage_by_collection, c.id, 0)
    end)
  end

  defp format_bytes(0), do: "0 B"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when bytes < 1_073_741_824 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end
end
