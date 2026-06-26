defmodule MagusWeb.SettingsLive.KnowledgeLive do
  @moduledoc """
  Settings page for managing knowledge sources.
  """

  use MagusWeb, :live_view

  alias Magus.Knowledge
  alias Magus.Knowledge.Connector
  alias MagusWeb.Knowledge.Components.ConnectSourceWizard
  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> init_assigns(user)
     |> assign(:resume_wizard_provider, params["wizard_provider"])
     |> assign(:oauth_tokens, session["knowledge_oauth_tokens"])}
  end

  @doc false
  def init_assigns(socket, _user) do
    socket
    |> assign(:page_title, gettext("Connected Sources"))
    |> assign(:current_path, "/settings/knowledge")
    |> assign(:resume_wizard_provider, nil)
    |> assign(:oauth_tokens, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} bg_class="bg-spectral">
      <:notification_bell>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count}
        />
      </:notification_bell>

      <div class="container mx-auto max-w-4xl py-8 px-4">
        <h1 class="text-2xl font-bold mb-6">{gettext("Settings")}</h1>

        <.page_with_sidebar_nav nav_items={
          MagusWeb.SettingsLive.settings_nav_items(@current_path, @current_user)
        }>
          <.live_component
            module={MagusWeb.Knowledge.KnowledgeSourcesComponent}
            id="knowledge-sources"
            scope={:personal}
            current_user={@current_user}
            resume_wizard_provider={@resume_wizard_provider}
            oauth_tokens={@oauth_tokens}
          />
        </.page_with_sidebar_nav>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  def render_knowledge_section(assigns) do
    ~H"""
    <.live_component
      module={MagusWeb.Knowledge.KnowledgeSourcesComponent}
      id="knowledge-sources"
      scope={:personal}
      current_user={@current_user}
      resume_wizard_provider={@resume_wizard_provider}
      oauth_tokens={@oauth_tokens}
    />
    """
  end

  @impl true
  def handle_info(
        {MagusWeb.Knowledge.Components.ConnectSourceWizard, {:wizard_complete, source_id}},
        socket
      ) do
    send_update(MagusWeb.Knowledge.KnowledgeSourcesComponent,
      id: "knowledge-sources",
      wizard_complete: true,
      expand_source_id: source_id
    )

    {:noreply, socket}
  end

  def handle_info(
        {MagusWeb.Knowledge.Components.ConnectSourceWizard, :clear_oauth_tokens},
        socket
      ) do
    {:noreply, assign(socket, oauth_tokens: nil)}
  end

  def handle_info({MagusWeb.Knowledge.Components.ConnectSourceWizard, :close_wizard}, socket) do
    send_update(MagusWeb.Knowledge.KnowledgeSourcesComponent,
      id: "knowledge-sources",
      wizard_complete: false,
      close_wizard: true
    )

    {:noreply, socket}
  end

  def handle_info({:subscribe_knowledge_sources, source_ids}, socket) do
    Enum.each(source_ids, fn id ->
      Phoenix.PubSub.subscribe(Magus.PubSub, "knowledge:source:#{id}")
    end)

    {:noreply, socket}
  end

  def handle_info(%{type: "sync." <> _}, socket) do
    send_update(MagusWeb.Knowledge.KnowledgeSourcesComponent,
      id: "knowledge-sources",
      refresh: true
    )

    {:noreply, socket}
  end

  # Async folder loading for the connect wizard — connects to the provider and
  # lists top-level folders, then pushes results back to the wizard component.
  def handle_info({ConnectSourceWizard, {:load_folders_async, source}}, socket) do
    case Connector.connector_for(source.provider) do
      {:error, _} ->
        send_update(ConnectSourceWizard,
          id: "connect-wizard",
          _folders_result: {:error, :unsupported_provider}
        )

      connector_module ->
        case connector_module.connect(source.auth_config) do
          {:ok, connection} ->
            folders =
              case connector_module.list_folders(connection, nil) do
                {:ok, f} -> f
                _ -> []
              end

            send_update(ConnectSourceWizard,
              id: "connect-wizard",
              _folders_result: {:ok, connection, folders}
            )

          {:error, reason} ->
            send_update(ConnectSourceWizard,
              id: "connect-wizard",
              _folders_result: {:error, reason}
            )
        end
    end

    {:noreply, socket}
  end

  # Async OAuth source creation — find existing source or create new one, then load folders.
  def handle_info({ConnectSourceWizard, {:create_oauth_source, provider, tokens}}, socket) do
    user = socket.assigns.current_user

    # Find existing source for this provider to avoid duplicates
    existing =
      case Knowledge.list_sources_for_user(actor: user) do
        {:ok, sources} -> Enum.find(sources, &(&1.provider == provider))
        _ -> nil
      end

    result =
      if existing do
        # Update auth config on existing source
        Knowledge.update_source_auth_config(existing, %{auth_config: tokens}, actor: user)
      else
        attrs = %{
          name: ConnectSourceWizard.provider_display_name(provider),
          provider: provider,
          auth_config: tokens
        }

        case Knowledge.create_source(attrs, actor: user) do
          {:ok, source} ->
            Knowledge.update_source_status(source, %{status: :active}, actor: user)
            {:ok, source}

          error ->
            error
        end
      end

    case result do
      {:ok, source} ->
        send(self(), {ConnectSourceWizard, {:load_folders_async, source}})

        send_update(ConnectSourceWizard,
          id: "connect-wizard",
          _oauth_source_result: {:ok, source}
        )

      {:error, error} ->
        send_update(ConnectSourceWizard,
          id: "connect-wizard",
          _oauth_source_result: {:error, error}
        )
    end

    {:noreply, socket}
  end

  # Catch-all for other PubSub messages
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
