defmodule MagusWeb.AgentsLive.Components.ConnectIntegrationWizard do
  @moduledoc """
  A 3-step modal wizard LiveComponent for connecting integrations to an agent.

  Steps:
    1. Provider Picker — grouped grid of available provider cards
    2. Authentication — API key form, OAuth redirect, or auto-connect
    3. Confirmation — success message with next steps
  """

  use MagusWeb, :live_component

  alias Magus.Integrations

  @source_type_labels %{
    channel: "Channels",
    tool_provider: "Tools",
    data_source: "Data Sources"
  }

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       step: 1,
       provider: nil,
       provider_meta: nil,
       providers: [],
       auth_error: nil,
       connecting: false,
       integration: nil,
       config: %{},
       generated_api_key: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      assign(socket,
        id: assigns.id,
        agent_id: assigns.agent_id,
        current_user: assigns.current_user,
        connected_provider_keys: assigns.connected_provider_keys,
        show: assigns.show
      )

    providers =
      load_and_filter_providers(assigns.connected_provider_keys, socket.assigns.current_user)

    socket = assign(socket, :providers, providers)

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.modal show={@show} on_close="close_wizard" target={@myself} size={:lg}>
        <:title>{step_title(@step)}</:title>

        <%= case @step do %>
          <% 1 -> %>
            {render_provider_picker(assigns)}
          <% 2 -> %>
            {render_auth_step(assigns)}
          <% 3 -> %>
            {render_confirmation(assigns)}
        <% end %>
      </.modal>
    </div>
    """
  end

  # -- Step 1: Provider Picker ------------------------------------------------

  defp render_provider_picker(assigns) do
    grouped =
      assigns.providers
      |> Enum.group_by(& &1.source_type)
      |> Enum.sort_by(fn {type, _} ->
        case type do
          :channel -> 0
          :tool_provider -> 1
          :data_source -> 2
          _ -> 3
        end
      end)

    assigns = assign(assigns, :grouped_providers, grouped)

    ~H"""
    <div class="space-y-6">
      <div :for={{source_type, providers} <- @grouped_providers}>
        <h4 class="text-sm font-semibold text-base-content/60 uppercase tracking-wider mb-3">
          {source_type_label(source_type)}
        </h4>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <button
            :for={provider <- providers}
            type="button"
            class="card bg-base-200 hover:bg-base-300 border border-base-300 hover:border-primary/40 transition-all cursor-pointer p-4 text-left"
            phx-click="select_provider"
            phx-value-provider={provider.key}
            phx-target={@myself}
          >
            <div class="flex flex-col items-center gap-3 text-center">
              <MagusWeb.BrandIcons.provider_icon provider={provider.key} class="size-10" />
              <div>
                <div class="flex items-center justify-center gap-1.5">
                  <span class="font-medium">{provider.name}</span>
                  <span :if={provider.requires_admin?} class="badge badge-xs badge-warning">
                    Admin
                  </span>
                </div>
                <div class="text-xs text-base-content/50 mt-0.5">{provider.description}</div>
              </div>
            </div>
          </button>
        </div>
      </div>

      <p :if={@grouped_providers == []} class="text-sm text-base-content/40 text-center py-8">
        {gettext("No integrations available to connect.")}
      </p>
    </div>
    """
  end

  # -- Step 2: Authentication -------------------------------------------------

  defp render_auth_step(assigns) do
    auth_help = get_auth_help(assigns.provider)
    assigns = assign(assigns, :auth_help, auth_help)

    ~H"""
    <div>
      <div class="flex items-center gap-3 mb-6">
        <MagusWeb.BrandIcons.provider_icon provider={@provider} class="size-10" />
        <div class="font-medium text-lg">{@provider_meta.name}</div>
      </div>

      <%= case @provider_meta.auth_type do %>
        <% :api_key -> %>
          {render_api_key_form(assigns)}
        <% {_, :oauth2} -> %>
          {render_oauth_step(assigns)}
        <% _ -> %>
          {render_auto_connect(assigns)}
      <% end %>
    </div>
    """
  end

  defp render_api_key_form(assigns) do
    ~H"""
    <div>
      <div :if={@auth_help} class="flex items-start gap-2 rounded-lg bg-info/10 p-3 mb-4 text-sm">
        <.icon name="lucide-info" class="size-4 text-info shrink-0 mt-0.5" />
        <div>
          <p class="text-base-content/70 whitespace-pre-line">{String.trim(@auth_help.text)}</p>
          <a
            :if={Map.get(@auth_help, :url)}
            href={@auth_help.url}
            target="_blank"
            rel="noopener noreferrer"
            class="link link-info text-xs mt-1 inline-flex items-center gap-1"
          >
            {Map.get(@auth_help, :url_label, gettext("Documentation"))}
            <.icon name="lucide-external-link" class="size-3" />
          </a>
        </div>
      </div>

      <.form for={%{}} as={:auth} phx-submit="connect" phx-target={@myself}>
        <div class="space-y-4">
          <%= for field <- @provider_meta.auth_fields do %>
            <div>
              <.input
                type={to_string(field.type)}
                name={"auth[#{field.name}]"}
                value=""
                label={field.label}
                placeholder={Map.get(field, :placeholder, "")}
                required
              />
              <p :if={Map.get(field, :help)} class="text-xs text-base-content/50 mt-1">
                {field.help}
              </p>
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
    </div>
    """
  end

  defp render_oauth_step(assigns) do
    ~H"""
    <div>
      <div :if={@auth_help} class="flex items-start gap-2 rounded-lg bg-info/10 p-3 mb-4 text-sm">
        <.icon name="lucide-info" class="size-4 text-info shrink-0 mt-0.5" />
        <div>
          <p class="text-base-content/70 whitespace-pre-line">{String.trim(@auth_help.text)}</p>
          <a
            :if={Map.get(@auth_help, :url)}
            href={@auth_help.url}
            target="_blank"
            rel="noopener noreferrer"
            class="link link-info text-xs mt-1 inline-flex items-center gap-1"
          >
            {Map.get(@auth_help, :url_label, gettext("Documentation"))}
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
            href={oauth_authorize_url(@provider_meta)}
            class="btn btn-primary"
          >
            <.icon name="lucide-external-link" class="w-4 h-4" />
            {gettext("Connect with %{name}", name: @provider_meta.name)}
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp render_auto_connect(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 gap-3">
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="text-sm text-base-content/60">
        {gettext("Setting up %{name}...", name: @provider_meta.name)}
      </p>
    </div>
    """
  end

  # -- Step 3: Confirmation ---------------------------------------------------

  defp render_confirmation(%{provider: :api, generated_api_key: api_key} = assigns)
       when is_binary(api_key) do
    curl_example =
      "curl -X POST #{Magus.Endpoint.url()}/api/v1/messages \\\n" <>
        "  -H \"Authorization: Bearer #{api_key}\" \\\n" <>
        "  -H \"Content-Type: application/json\" \\\n" <>
        "  -d '{\"content\": \"Hello!\"}'"

    assigns = assign(assigns, :curl_example, curl_example)

    ~H"""
    <div class="py-6">
      <div class="flex justify-center mb-4">
        <div class="w-16 h-16 bg-success/10 rounded-full flex items-center justify-center">
          <.icon name="lucide-check-circle" class="size-8 text-success" />
        </div>
      </div>

      <h3 class="text-lg font-semibold mb-2 text-center">
        {gettext("API Integration Connected")}
      </h3>

      <p class="text-sm text-base-content/60 mb-4 text-center">
        {gettext("Your API key has been generated. Copy it now, it won't be shown again.")}
      </p>

      <div class="bg-base-200 rounded-lg p-4 mb-4">
        <label class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2 block">
          {gettext("API Key")}
        </label>
        <div class="flex items-center gap-2">
          <code
            id="api-key-value"
            class="flex-1 text-sm font-mono bg-base-300 rounded px-3 py-2 break-all select-all"
          >
            {@generated_api_key}
          </code>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square shrink-0"
            phx-click={
              JS.dispatch("phx:copy", to: "#api-key-value")
              |> JS.hide(to: "#copy-icon")
              |> JS.show(to: "#copied-icon")
              |> JS.add_class("text-success")
            }
            title={gettext("Copy to clipboard")}
          >
            <span id="copy-icon"><.icon name="lucide-copy" class="size-4" /></span>
            <span id="copied-icon" class="hidden">
              <.icon name="lucide-check" class="size-4" />
            </span>
          </button>
        </div>
      </div>

      <div class="flex items-start gap-2 rounded-lg bg-warning/10 p-3 mb-4 text-sm">
        <.icon name="lucide-alert-triangle" class="size-4 text-warning shrink-0 mt-0.5" />
        <p class="text-base-content/70">
          {gettext(
            "Store this key securely. You will not be able to see it again. If lost, disconnect and reconnect to generate a new key."
          )}
        </p>
      </div>

      <div class="bg-base-200 rounded-lg p-4 text-sm">
        <p class="font-medium mb-2">{gettext("Quick start")}</p>
        <p class="text-base-content/60 mb-2">
          {gettext("Send messages to your agent via the REST API:")}
        </p>
        <code class="block text-xs font-mono bg-base-300 rounded px-3 py-2 whitespace-pre overflow-x-auto">
          {@curl_example}
        </code>
      </div>

      <div class="flex justify-center mt-6">
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="done"
          phx-target={@myself}
        >
          {gettext("Done")}
        </button>
      </div>
    </div>
    """
  end

  defp render_confirmation(assigns) do
    ~H"""
    <div class="text-center py-8">
      <div class="flex justify-center mb-4">
        <div class="w-16 h-16 bg-success/10 rounded-full flex items-center justify-center">
          <.icon name="lucide-check-circle" class="size-8 text-success" />
        </div>
      </div>

      <h3 class="text-lg font-semibold mb-2">
        {gettext("Successfully connected %{name}!", name: provider_name(@provider_meta))}
      </h3>

      <p class="text-sm text-base-content/60 mb-6">
        {next_steps_text(@provider)}
      </p>

      <div class="flex justify-center gap-2">
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="done"
          phx-target={@myself}
        >
          {gettext("Done")}
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("close_wizard", _params, socket) do
    send(self(), :wizard_closed)
    {:noreply, reset_state(socket)}
  end

  def handle_event("select_provider", %{"provider" => "custom_api"}, socket) do
    # Skip wizard — go straight to AI-guided setup conversation
    {:noreply, push_navigate(socket, to: ~p"/chat?skill=api_integration_setup")}
  end

  def handle_event("select_provider", %{"provider" => provider_key}, socket) do
    provider = String.to_existing_atom(provider_key)
    provider_meta = Enum.find(socket.assigns.providers, &(&1.key == provider))

    socket =
      assign(socket, step: 2, provider: provider, provider_meta: provider_meta, auth_error: nil)

    # Auto-connect for providers that need no auth
    socket =
      if provider_meta && provider_meta.auth_type in [:none, :webhook_only] do
        auto_connect(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply, assign(socket, step: 1, provider: nil, provider_meta: nil, auth_error: nil)}
  end

  def handle_event("connect", params, socket) do
    auth_params = Map.get(params, "auth", %{})
    socket = assign(socket, connecting: true, auth_error: nil)

    result =
      Reactor.run(
        Magus.Integrations.Reactors.SetupIntegration,
        %{
          user_id: socket.assigns.current_user.id,
          custom_agent_id: socket.assigns.agent_id,
          provider_key: socket.assigns.provider,
          credentials: auth_params,
          config: %{}
        },
        async?: false
      )

    case result do
      {:ok, integration} ->
        {:noreply,
         assign(socket,
           step: 3,
           connecting: false,
           integration: integration
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           auth_error: format_error(reason),
           connecting: false
         )}
    end
  end

  def handle_event("done", _params, socket) do
    send(self(), {:wizard_complete, socket.assigns.integration})
    {:noreply, reset_state(socket)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_and_filter_providers(connected_keys, current_user) do
    is_admin = current_user.is_admin || false

    Integrations.list_available_providers()
    |> Enum.reject(fn p ->
      p.source_type == :knowledge or
        p.key == :simple_webhook or
        p.key in connected_keys or
        (p.requires_admin? and not is_admin)
    end)
  end

  defp auto_connect(socket) do
    result =
      Reactor.run(
        Magus.Integrations.Reactors.SetupIntegration,
        %{
          user_id: socket.assigns.current_user.id,
          custom_agent_id: socket.assigns.agent_id,
          provider_key: socket.assigns.provider,
          credentials: %{},
          config: %{}
        },
        async?: false
      )

    case result do
      {:ok, integration} ->
        socket = assign(socket, step: 3, integration: integration)
        maybe_load_generated_api_key(socket, integration)

      {:error, reason} ->
        assign(socket, auth_error: format_error(reason), step: 2)
    end
  end

  defp maybe_load_generated_api_key(socket, integration) do
    if socket.assigns.provider == :api do
      case Integrations.load_credentials(integration.id) do
        {:ok, %{"api_key" => api_key}} -> assign(socket, :generated_api_key, api_key)
        _ -> socket
      end
    else
      socket
    end
  end

  defp reset_state(socket) do
    assign(socket,
      step: 1,
      provider: nil,
      provider_meta: nil,
      auth_error: nil,
      connecting: false,
      integration: nil,
      config: %{},
      generated_api_key: nil
    )
  end

  defp step_title(1), do: gettext("Connect an Integration")
  defp step_title(2), do: gettext("Authenticate")
  defp step_title(3), do: gettext("Connected")

  defp source_type_label(type), do: Map.get(@source_type_labels, type, to_string(type))

  defp provider_name(%{name: name}), do: name
  defp provider_name(_), do: ""

  defp get_auth_help(provider_key) when is_atom(provider_key) do
    Integrations.auth_help(provider_key)
  end

  defp get_auth_help(_), do: nil

  defp oauth_authorize_url(%{oauth_config: %{authorize_url: url}}) when is_binary(url), do: url

  defp oauth_authorize_url(%{key: key}) do
    "/oauth/#{key}/authorize"
  end

  defp oauth_authorize_url(_), do: "#"

  defp next_steps_text(:api) do
    gettext("Your API integration is ready. Use your API key to send messages to your agent.")
  end

  defp next_steps_text(:telegram) do
    gettext("Your Telegram bot is ready. Send it a message to start chatting with your agent.")
  end

  defp next_steps_text(:google_calendar) do
    gettext("Google Calendar is connected. Your agent can now access your calendar events.")
  end

  defp next_steps_text(:rss_source) do
    gettext("RSS feed is connected and will be synced periodically.")
  end

  defp next_steps_text(:log_source) do
    gettext("Log source is connected. Logs will be ingested automatically.")
  end

  defp next_steps_text(_) do
    gettext("The integration is active and ready to use.")
  end

  defp format_error(%Reactor.Error.Invalid{errors: [%{error: error} | _]}) do
    format_error(error)
  end

  defp format_error(%Ash.Error.Invalid{} = error) do
    case Ash.Error.Invalid.message(error) do
      msg when is_binary(msg) -> msg
      _ -> gettext("Failed to connect integration")
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(_), do: gettext("Connection failed. Please check your credentials.")
end
