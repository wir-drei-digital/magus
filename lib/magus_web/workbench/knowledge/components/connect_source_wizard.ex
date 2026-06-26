defmodule MagusWeb.Knowledge.Components.ConnectSourceWizard do
  @moduledoc """
  A 3-step modal wizard LiveComponent for connecting knowledge sources.

  Steps:
    1. Provider Picker — grid of provider cards
    2. Authentication — API key form or OAuth placeholder
    3. Folder Picker — tree of folders with checkboxes for selection
  """

  use MagusWeb, :live_component

  import MagusWeb.Knowledge.Components.KnowledgeSourceCard, only: [provider_icon: 1]

  alias Magus.Integrations
  alias Magus.Knowledge
  alias Magus.Knowledge.Connector

  # Maps connector key → integration provider key for OAuth flows
  @oauth_provider_keys %{
    notion: :notion_knowledge,
    google_drive: :google_drive_knowledge
  }

  @providers [
    %{key: :notion, name: "Notion", description: "Pages and databases", auth: :oauth},
    %{key: :google_drive, name: "Google Drive", description: "Files and folders", auth: :oauth},
    %{key: :nextcloud, name: "Nextcloud", description: "Files via WebDAV", auth: :api_key},
    %{key: :web, name: "Web", description: "Websites, docs, and APIs", auth: :api_key}
  ]

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       step: 1,
       provider: nil,
       auth_error: nil,
       connecting: false,
       source: nil,
       connection: nil,
       folders: [],
       folder_children: %{},
       expanded_folder_ids: MapSet.new(),
       selected_folders: MapSet.new(),
       loading_folders: MapSet.new(),
       syncing: false,
       selected_folder_meta: %{},
       existing_source_loaded: false,
       oauth_consumed: false,
       loading_connection: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    # Handle async results from parent LiveView (via send_update)
    socket =
      cond do
        assigns[:_folders_result] ->
          handle_folders_result(socket, assigns._folders_result)

        assigns[:_oauth_source_result] ->
          handle_oauth_source_result(socket, assigns._oauth_source_result)

        true ->
          socket =
            assign(socket,
              current_user: assigns.current_user,
              scope: assigns.scope,
              resume_wizard_provider: assigns[:resume_wizard_provider]
            )

          # Handle OAuth return — tokens come from session via parent LiveView.
          # We consume the tokens once and notify the parent to clear them,
          # preventing duplicate source creation on subsequent update cycles.
          socket =
            if assigns[:oauth_tokens] && !socket.assigns.oauth_consumed do
              send(self(), {__MODULE__, :clear_oauth_tokens})
              handle_oauth_return(socket, assigns.oauth_tokens)
            else
              socket
            end

          # Handle existing source shortcut — show modal immediately, load folders async
          socket =
            if assigns[:wizard_existing_source] && !socket.assigns[:existing_source_loaded] do
              source = assigns.wizard_existing_source
              send(self(), {__MODULE__, {:load_folders_async, source}})

              assign(socket,
                step: 3,
                source: source,
                provider: source.provider,
                existing_source_loaded: true,
                loading_connection: true
              )
            else
              socket
            end

          socket
      end

    {:ok, socket}
  end

  defp handle_folders_result(socket, {:ok, connection, folders}) do
    assign(socket, connection: connection, folders: folders, loading_connection: false)
  end

  defp handle_folders_result(socket, {:error, reason}) do
    assign(socket, auth_error: format_error(reason), loading_connection: false, step: 2)
  end

  defp handle_oauth_source_result(socket, {:ok, source}) do
    assign(socket, source: source)
  end

  defp handle_oauth_source_result(socket, {:error, error}) do
    assign(socket, auth_error: format_error(error), loading_connection: false, step: 2)
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal show={true} on_close="close_wizard" target={@myself} size={:lg}>
        <:title>{step_title(@step)}</:title>

        <%= case @step do %>
          <% 1 -> %>
            {render_provider_picker(assigns)}
          <% 2 -> %>
            {render_auth_step(assigns)}
          <% 3 -> %>
            {render_folder_picker(assigns)}
        <% end %>
      </.modal>
    </div>
    """
  end

  # -- Step 1: Provider Picker ------------------------------------------------

  defp render_provider_picker(assigns) do
    is_admin = assigns.current_user && assigns.current_user.is_admin

    providers =
      Enum.reject(@providers, fn p ->
        Integrations.requires_admin?(p.key) and not is_admin
      end)

    assigns = assign(assigns, :providers, providers)

    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <button
        :for={provider <- @providers}
        type="button"
        class="card bg-base-200 hover:bg-base-300 border border-base-300 hover:border-primary/40 transition-all cursor-pointer p-4 text-left"
        phx-click="select_provider"
        phx-value-provider={provider.key}
        phx-target={@myself}
      >
        <div class="flex flex-col items-center gap-3 text-center relative">
          <.provider_icon provider={provider.key} size={:lg} />
          <div>
            <div class="font-medium">{provider.name}</div>
            <div class="text-xs text-base-content/50 mt-0.5">{provider.description}</div>
          </div>
          <span
            :if={Integrations.requires_admin?(provider.key)}
            class="badge badge-xs badge-warning absolute top-0 right-0"
          >
            Admin
          </span>
        </div>
      </button>
    </div>
    """
  end

  # -- Step 2: Authentication -------------------------------------------------

  defp render_auth_step(assigns) do
    provider_meta = Enum.find(@providers, &(&1.key == assigns.provider))
    assigns = assign(assigns, :provider_meta, provider_meta)

    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <.provider_icon provider={@provider} size={:md} />
        <div class="font-medium text-lg">{@provider_meta.name}</div>
      </div>

      <%= if @provider_meta.auth == :oauth do %>
        <% auth_help = Integrations.auth_help(@provider) %>
        <div :if={auth_help} class="flex items-start gap-2 rounded-lg bg-info/10 p-3 mb-4 text-sm">
          <.icon name="lucide-info" class="size-4 text-info shrink-0 mt-0.5" />
          <div>
            <p class="text-base-content/70">{auth_help.text}</p>
            <a
              :if={Map.get(auth_help, :url)}
              href={auth_help.url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-info text-xs mt-1 inline-flex items-center gap-1"
            >
              {Map.get(auth_help, :url_label, gettext("Documentation"))}
              <.icon name="lucide-external-link" class="size-3" />
            </a>
          </div>
        </div>

        <div class="text-center py-8">
          <h3 class="text-lg font-semibold mb-2">
            {gettext("Connect %{name}", name: @provider_meta.name)}
          </h3>
          <p class="text-sm text-base-content/60 mb-6">
            {gettext("You'll be redirected to sign in and grant access")}
          </p>
          <div class="flex justify-center gap-2">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="back_to_providers"
              phx-target={@myself}
            >
              {gettext("Back")}
            </button>
            <.link
              href={oauth_authorize_url(@provider)}
              class="btn btn-primary"
            >
              <.icon name="lucide-external-link" class="w-4 h-4" />
              {gettext("Connect with %{name}", name: @provider_meta.name)}
            </.link>
          </div>
        </div>
      <% else %>
        <% auth_help = Integrations.auth_help(@provider) %>
        <div :if={auth_help} class="flex items-start gap-2 rounded-lg bg-info/10 p-3 mb-4 text-sm">
          <.icon name="lucide-info" class="size-4 text-info shrink-0 mt-0.5" />
          <div>
            <p class="text-base-content/70">{auth_help.text}</p>
            <a
              :if={Map.get(auth_help, :url)}
              href={auth_help.url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-info text-xs mt-1 inline-flex items-center gap-1"
            >
              {Map.get(auth_help, :url_label, gettext("Documentation"))}
              <.icon name="lucide-external-link" class="size-3" />
            </a>
          </div>
        </div>

        <.form for={%{}} as={:auth} phx-submit="connect" phx-target={@myself}>
          <div class="space-y-4">
            <%= for field <- auth_fields(@provider) do %>
              <div>
                <label class="label">
                  <span class="label-text">{field.label}</span>
                </label>
                <input
                  type={field.type}
                  name={"auth[#{field.name}]"}
                  placeholder={field.placeholder}
                  required
                  class="input input-bordered w-full"
                />
              </div>
            <% end %>
          </div>

          <div :if={@auth_error} class="alert alert-error alert-sm mt-4 text-sm">
            <.icon name="lucide-alert-circle" class="size-4" />
            <span>{@auth_error}</span>
          </div>

          <div class="flex items-center justify-between mt-6">
            <button
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="back_to_providers"
              phx-target={@myself}
            >
              <.icon name="lucide-arrow-left" class="size-4" />
              {gettext("Back")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm" disabled={@connecting}>
              <%= if @connecting do %>
                <span class="loading loading-spinner loading-sm"></span>
                {gettext("Connecting...")}
              <% else %>
                {gettext("Connect")}
              <% end %>
            </button>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

  # -- Step 3: Folder Picker --------------------------------------------------

  defp render_folder_picker(assigns) do
    ~H"""
    <div>
      <%= if @loading_connection do %>
        <div class="flex flex-col items-center justify-center py-12 gap-3">
          <span class="loading loading-spinner loading-lg text-primary"></span>
          <p class="text-sm text-base-content/60">
            {gettext("Connecting and loading folders...")}
          </p>
        </div>
      <% else %>
        <p class="text-sm text-base-content/60 mb-4">
          {gettext("Select folders to sync as collections.")}
        </p>

        <div class="max-h-80 overflow-y-auto border border-base-300 rounded-lg p-2">
          <%= if Enum.empty?(@folders) do %>
            <p class="text-sm text-base-content/40 py-4 text-center">
              {gettext("No folders found")}
            </p>
          <% else %>
            <div class="space-y-0.5">
              <%= for folder <- @folders do %>
                {render_folder_tree(assigns, folder, 0)}
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <div class="flex items-center justify-between mt-6">
        <div class="flex items-center gap-4">
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="wizard_back"
            phx-target={@myself}
          >
            <.icon name="lucide-arrow-left" class="size-4" />
            {gettext("Back")}
          </button>
          <div class="text-sm text-base-content/50">
            {ngettext(
              "%{count} folder selected",
              "%{count} folders selected",
              MapSet.size(@selected_folders)
            )}
          </div>
        </div>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          disabled={MapSet.size(@selected_folders) == 0 || @syncing}
          phx-click="start_sync"
          phx-target={@myself}
        >
          <%= if @syncing do %>
            <span class="loading loading-spinner loading-sm"></span>
            {gettext("Starting sync...")}
          <% else %>
            <.icon name="lucide-download" class="size-4" />
            {gettext("Start Sync")}
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  defp render_folder_tree(assigns, folder, depth) do
    expanded = MapSet.member?(assigns.expanded_folder_ids, folder.id)
    selected = MapSet.member?(assigns.selected_folders, folder.id)
    loading = MapSet.member?(assigns.loading_folders, folder.id)
    children = Map.get(assigns.folder_children, folder.id, [])

    selectable = Map.get(folder, :selectable, true)

    assigns =
      assigns
      |> assign(:folder, folder)
      |> assign(:depth, depth)
      |> assign(:expanded, expanded)
      |> assign(:selected, selected)
      |> assign(:loading, loading)
      |> assign(:children, children)
      |> assign(:selectable, selectable)

    ~H"""
    <div>
      <div
        class="flex items-center gap-2 rounded-md hover:bg-base-200 px-2 py-1.5 cursor-pointer"
        style={"padding-left: #{@depth * 1.5 + 0.5}rem"}
      >
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-circle"
          phx-click="toggle_folder_expand"
          phx-value-id={@folder.id}
          phx-target={@myself}
        >
          <%= cond do %>
            <% @loading -> %>
              <span class="loading loading-spinner loading-xs"></span>
            <% @expanded -> %>
              <.icon name="lucide-chevron-down" class="size-3.5" />
            <% true -> %>
              <.icon name="lucide-chevron-right" class="size-3.5" />
          <% end %>
        </button>

        <label class="flex items-center gap-2 flex-1 cursor-pointer">
          <input
            type="checkbox"
            class="checkbox checkbox-sm checkbox-primary"
            checked={@selected}
            phx-click="toggle_folder_select"
            phx-value-id={@folder.id}
            phx-value-name={@folder.name}
            phx-value-path={@folder.path}
            phx-target={@myself}
          />
          <.icon
            name={
              if Map.get(@folder, :icon, "folder") == "database",
                do: "lucide-database",
                else: "lucide-file-text"
            }
            class="size-4 text-base-content/50"
          />
          <span class="text-sm truncate">{@folder.name}</span>
        </label>
      </div>

      <div :if={@expanded && @children != []}>
        <%= for child <- @children do %>
          {render_folder_tree(assigns, child, @depth + 1)}
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("close_wizard", _params, socket) do
    send(self(), {__MODULE__, :close_wizard})
    {:noreply, socket}
  end

  def handle_event("select_provider", %{"provider" => provider_key}, socket) do
    provider = String.to_existing_atom(provider_key)
    {:noreply, assign(socket, step: 2, provider: provider, auth_error: nil)}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply, assign(socket, step: 1, provider: nil, auth_error: nil)}
  end

  def handle_event("wizard_back", _params, socket) do
    {:noreply, assign(socket, step: 2, auth_error: nil)}
  end

  def handle_event("connect", %{"auth" => auth_params}, socket) do
    provider = socket.assigns.provider

    case Connector.connector_for(provider) do
      {:error, _} ->
        {:noreply, assign(socket, auth_error: gettext("Unsupported provider"), connecting: false)}

      connector ->
        socket = assign(socket, connecting: true)

        case connector.connect(auth_params) do
          {:ok, _connection} ->
            # Create the knowledge source
            source_attrs = %{
              name: provider_display_name(provider),
              provider: provider,
              auth_config: auth_params
            }

            source_attrs =
              case socket.assigns.scope do
                {:workspace, workspace_id} -> Map.put(source_attrs, :workspace_id, workspace_id)
                :personal -> source_attrs
              end

            case Knowledge.create_source(source_attrs, actor: socket.assigns.current_user) do
              {:ok, source} ->
                # Mark source as active
                Knowledge.update_source_status(source, %{status: :active},
                  actor: socket.assigns.current_user
                )

                # Load folders async — show modal with loading state immediately
                send(self(), {__MODULE__, {:load_folders_async, source}})

                {:noreply,
                 assign(socket,
                   step: 3,
                   source: source,
                   connecting: false,
                   loading_connection: true
                 )}

              {:error, error} ->
                {:noreply,
                 assign(socket,
                   auth_error: format_error(error),
                   connecting: false
                 )}
            end

          {:error, reason} ->
            {:noreply,
             assign(socket,
               auth_error: format_error(reason),
               connecting: false
             )}
        end
    end
  end

  def handle_event("toggle_folder_expand", %{"id" => folder_id}, socket) do
    expanded = socket.assigns.expanded_folder_ids

    if MapSet.member?(expanded, folder_id) do
      # Collapse
      {:noreply, assign(socket, expanded_folder_ids: MapSet.delete(expanded, folder_id))}
    else
      # Expand — load children if not already loaded
      if Map.has_key?(socket.assigns.folder_children, folder_id) do
        {:noreply, assign(socket, expanded_folder_ids: MapSet.put(expanded, folder_id))}
      else
        # Start loading
        socket =
          assign(socket,
            loading_folders: MapSet.put(socket.assigns.loading_folders, folder_id),
            expanded_folder_ids: MapSet.put(expanded, folder_id)
          )

        case Connector.connector_for(socket.assigns.provider) do
          {:error, _} ->
            {:noreply,
             assign(socket,
               folder_children: Map.put(socket.assigns.folder_children, folder_id, []),
               loading_folders: MapSet.delete(socket.assigns.loading_folders, folder_id)
             )}

          connector ->
            case connector.list_folders(socket.assigns.connection, folder_id) do
              {:ok, children} ->
                {:noreply,
                 assign(socket,
                   folder_children: Map.put(socket.assigns.folder_children, folder_id, children),
                   loading_folders: MapSet.delete(socket.assigns.loading_folders, folder_id)
                 )}

              {:error, _} ->
                {:noreply,
                 assign(socket,
                   folder_children: Map.put(socket.assigns.folder_children, folder_id, []),
                   loading_folders: MapSet.delete(socket.assigns.loading_folders, folder_id)
                 )}
            end
        end
      end
    end
  end

  def handle_event("toggle_folder_select", %{"id" => folder_id} = params, socket) do
    selected = socket.assigns.selected_folders

    selected =
      if MapSet.member?(selected, folder_id) do
        MapSet.delete(selected, folder_id)
      else
        # Store folder info for later use when creating collections
        MapSet.put(selected, folder_id)
      end

    # Also store folder metadata for creating collections
    folder_meta = %{
      id: folder_id,
      name: Map.get(params, "name", folder_id),
      path: Map.get(params, "path", "")
    }

    existing_meta = Map.get(socket.assigns, :selected_folder_meta, %{})
    folder_meta_map = Map.put(existing_meta, folder_id, folder_meta)

    {:noreply,
     assign(socket,
       selected_folders: selected,
       selected_folder_meta: folder_meta_map
     )}
  end

  def handle_event("start_sync", _params, socket) do
    socket = assign(socket, syncing: true)
    source = socket.assigns.source
    selected = socket.assigns.selected_folders
    folder_meta = Map.get(socket.assigns, :selected_folder_meta, %{})
    user = socket.assigns.current_user

    existing_collections =
      case Knowledge.list_collections_for_source(source.id, actor: user) do
        {:ok, cols} -> cols
        _ -> []
      end

    existing_by_external_id =
      Map.new(existing_collections, fn c -> {c.external_id, c} end)

    results =
      Enum.map(selected, fn folder_id ->
        meta = Map.get(folder_meta, folder_id, %{id: folder_id, name: folder_id, path: ""})

        case Map.get(existing_by_external_id, meta.id) do
          %{sync_status: :syncing} = existing ->
            {:ok, existing}

          %{} = existing ->
            Knowledge.trigger_full_sync(existing, actor: user)
            {:ok, existing}

          nil ->
            attrs = %{
              name: meta.name,
              external_id: meta.id,
              external_path: meta.path
            }

            case Knowledge.create_collection(source.id, attrs, actor: user) do
              {:ok, collection} ->
                Knowledge.trigger_full_sync(collection, actor: user)
                {:ok, collection}

              {:error, error} ->
                {:error, error}
            end
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      send(self(), {__MODULE__, {:wizard_complete, source.id}})
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         syncing: false,
         auth_error: gettext("Some collections failed to create. Please try again.")
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_title(1), do: gettext("Connect a Source")
  defp step_title(2), do: gettext("Authenticate")
  defp step_title(3), do: gettext("Select Folders")

  defp auth_fields(:notion) do
    [
      %{
        name: "api_key",
        label: gettext("API Key"),
        type: "password",
        placeholder: "ntn_..."
      }
    ]
  end

  defp auth_fields(:nextcloud) do
    [
      %{
        name: "base_url",
        label: gettext("Server URL"),
        type: "text",
        placeholder: "https://cloud.example.com"
      },
      %{
        name: "username",
        label: gettext("Username"),
        type: "text",
        placeholder: gettext("Your username")
      },
      %{
        name: "password",
        label: gettext("Password"),
        type: "password",
        placeholder: gettext("Your password or app token")
      }
    ]
  end

  defp auth_fields(:web) do
    [
      %{
        name: "seed_url",
        label: gettext("URL"),
        type: "text",
        placeholder: "https://docs.example.com"
      }
    ]
  end

  defp auth_fields(_), do: []

  # Called when the wizard reopens after an OAuth redirect with tokens in the session.
  # Only sets UI state — all side effects (source creation, folder loading) are deferred
  # to an async message to avoid duplicate creation from repeated update/2 calls.
  defp handle_oauth_return(socket, tokens) do
    provider =
      case socket.assigns[:provider] do
        nil ->
          case socket.assigns[:resume_wizard_provider] do
            p when is_binary(p) -> String.to_existing_atom(p)
            p when is_atom(p) -> p
            _ -> nil
          end

        p ->
          p
      end

    socket = assign(socket, oauth_consumed: true, provider: provider)

    if is_nil(provider) do
      socket
    else
      send(self(), {__MODULE__, {:create_oauth_source, provider, tokens}})

      assign(socket,
        step: 3,
        loading_connection: true
      )
    end
  end

  defp oauth_authorize_url(provider) do
    integration_key = Map.fetch!(@oauth_provider_keys, provider)
    return_to = "/settings/knowledge?wizard_provider=#{provider}"
    "/oauth/#{integration_key}/authorize?" <> URI.encode_query(%{"return_to" => return_to})
  end

  def provider_display_name(:notion), do: "Notion"
  def provider_display_name(:google_drive), do: "Google Drive"
  def provider_display_name(:nextcloud), do: "Nextcloud"
  def provider_display_name(:web), do: "Web"
  def provider_display_name(provider), do: provider |> Atom.to_string() |> String.capitalize()

  defp format_error(%Ash.Error.Invalid{} = error) do
    error
    |> Ash.Error.Invalid.message()
    |> case do
      msg when is_binary(msg) -> msg
      _ -> gettext("Failed to create source")
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(_error), do: gettext("Connection failed. Please check your credentials.")
end
