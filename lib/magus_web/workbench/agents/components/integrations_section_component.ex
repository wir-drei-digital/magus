defmodule MagusWeb.AgentsLive.Components.IntegrationsSectionComponent do
  @moduledoc """
  LiveComponent that manages the list of connected integrations for an agent,
  handles expand/collapse, and hosts the connect-integration wizard modal.
  """

  use MagusWeb, :live_component
  use Gettext, backend: MagusWeb.Gettext

  require Logger

  import MagusWeb.AgentsLive.Components.IntegrationCard

  alias Magus.Integrations

  @provider_icons %{
    telegram: "lucide-send",
    google_calendar: "lucide-calendar",
    rss_source: "lucide-rss",
    log_source: "lucide-file-text",
    api: "lucide-code"
  }

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def update(%{wizard_event: :complete}, socket) do
    {:ok,
     socket
     |> assign(:show_wizard, false)
     |> reload_integrations()}
  end

  def update(%{wizard_event: :closed}, socket) do
    {:ok, assign(socket, :show_wizard, false)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:agent_id, assigns.agent_id)
      |> assign(:current_user, assigns.current_user)

    # Initialize internal state on first mount
    socket =
      if socket.assigns[:expanded] do
        socket
      else
        socket
        |> assign(:expanded, MapSet.new())
        |> assign(:show_wizard, false)
        |> assign(:regenerated_api_key, nil)
      end

    socket = reload_integrations(socket)

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    grouped = group_integrations(assigns.integrations, assigns.provider_meta)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="space-y-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-lg font-medium text-base-content">
            {gettext("Integrations")}
          </h3>
          <p class="text-base-content/60 text-sm mt-1">
            {gettext("Connect external services to your agent")}
          </p>
        </div>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="connect_new"
          phx-target={@myself}
        >
          <.icon name="lucide-plus" class="w-4 h-4" />
          {gettext("Connect New")}
        </button>
      </div>

      <%!-- Empty state --%>
      <div :if={@integrations == []} class="text-center py-12">
        <div class="flex justify-center mb-4">
          <div class="w-16 h-16 bg-base-200 rounded-full flex items-center justify-center">
            <.icon name="lucide-plug" class="w-8 h-8 text-base-content/30" />
          </div>
        </div>
        <p class="text-base-content/50 mb-4">
          {gettext("No integrations connected yet")}
        </p>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="connect_new"
          phx-target={@myself}
        >
          <.icon name="lucide-plus" class="w-4 h-4" />
          {gettext("Connect your first integration")}
        </button>
      </div>

      <%!-- Connected integrations grouped by source type --%>
      <div :if={@integrations != []} class="space-y-6">
        <div :for={{source_type, integrations} <- @grouped}>
          <h4 class="text-xs text-base-content/50 uppercase tracking-wider mb-3">
            {source_type_label(source_type)}
          </h4>
          <div class="space-y-3">
            <.integration_card
              :for={integration <- integrations}
              integration={integration}
              provider_meta={
                Map.get(@provider_meta, integration.provider_key, %{
                  name: to_string(integration.provider_key),
                  source_type: :other,
                  has_tools: false
                })
              }
              icon={provider_icon(integration.provider_key)}
              expanded={MapSet.member?(@expanded, integration.id)}
              target={@myself}
              regenerated_api_key={if integration.provider_key == :api, do: @regenerated_api_key}
            />
          </div>
        </div>
      </div>

      <%!-- Wizard modal --%>
      <.live_component
        :if={@show_wizard}
        module={MagusWeb.AgentsLive.Components.ConnectIntegrationWizard}
        id="connect-wizard"
        agent_id={@agent_id}
        current_user={@current_user}
        connected_provider_keys={@connected_provider_keys}
        show={@show_wizard}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Event Handlers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("connect_new", _params, socket) do
    {:noreply, assign(socket, :show_wizard, true)}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded

    new_expanded =
      if MapSet.member?(expanded, id) do
        MapSet.delete(expanded, id)
      else
        MapSet.put(expanded, id)
      end

    {:noreply, assign(socket, :expanded, new_expanded)}
  end

  def handle_event("disconnect_integration", %{"id" => integration_id}, socket) do
    integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

    if integration do
      disconnect_integration_impl(
        integration,
        integration.provider_key,
        socket.assigns.current_user
      )

      {:noreply, reload_integrations(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "approve_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_integration_config(socket, integration_id, fn config ->
      pending = config["pending_approvals"] || []
      allowed = config["allowed_chat_ids"] || []

      new_pending = Enum.reject(pending, &(&1["chat_id"] == chat_id))
      new_allowed = if chat_id in allowed, do: allowed, else: allowed ++ [chat_id]

      config
      |> Map.put("pending_approvals", new_pending)
      |> Map.put("allowed_chat_ids", new_allowed)
    end)
  end

  def handle_event(
        "deny_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_integration_config(socket, integration_id, fn config ->
      pending = config["pending_approvals"] || []
      Map.put(config, "pending_approvals", Enum.reject(pending, &(&1["chat_id"] == chat_id)))
    end)
  end

  def handle_event(
        "remove_chat",
        %{"integration-id" => integration_id, "chat-id" => chat_id},
        socket
      ) do
    update_integration_config(socket, integration_id, fn config ->
      allowed = config["allowed_chat_ids"] || []
      Map.put(config, "allowed_chat_ids", Enum.reject(allowed, &(&1 == chat_id)))
    end)
  end

  def handle_event(
        "toggle_integration_tool",
        %{"integration-id" => integration_id, "tool" => tool},
        socket
      ) do
    integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

    if integration do
      enabled_tools = integration.enabled_tools || []

      new_tools =
        if tool in enabled_tools do
          List.delete(enabled_tools, tool)
        else
          [tool | enabled_tools]
        end

      case Integrations.update_integration_enabled_tools(
             integration,
             %{enabled_tools: new_tools},
             actor: socket.assigns.current_user
           ) do
        {:ok, _updated} ->
          {:noreply, reload_integrations(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update tools"))}
      end
    else
      {:noreply, socket}
    end
  end

  # --- Clipboard ---

  def handle_event("copy_to_clipboard", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
  end

  # --- API Key management ---

  def handle_event("regenerate_api_key", %{"integration-id" => integration_id}, socket) do
    alias Magus.Integrations.Providers.Api, as: ApiProvider

    integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

    if integration && integration.provider_key == :api do
      api_key = ApiProvider.generate_api_key()
      key_hash = ApiProvider.hash_api_key(api_key)
      prefix = ApiProvider.key_prefix(api_key)

      with {:ok, credential} <-
             Integrations.get_credential_for_integration(integration.id, authorize?: false),
           {:ok, _} <-
             Integrations.refresh_credential(
               credential,
               %{encrypted_data: %{"api_key" => api_key}, key_hash: key_hash},
               authorize?: false
             ),
           {:ok, updated_integration} <-
             Integrations.update_integration_config(
               integration,
               %{config: Map.merge(integration.config || %{}, %{"key_prefix" => prefix})},
               authorize?: false
             ),
           {:ok, _} <-
             Integrations.reactivate_if_errored(updated_integration, authorize?: false) do
        socket =
          socket
          |> assign(:regenerated_api_key, api_key)
          |> reload_integrations()

        {:noreply, socket}
      else
        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to regenerate API key"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_regenerated_key", _params, socket) do
    {:noreply, assign(socket, :regenerated_api_key, nil)}
  end

  # --- Log Source management ---

  def handle_event("regenerate_log_secret", %{"integration-id" => integration_id}, socket) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    update_integration_config(socket, integration_id, fn config ->
      Map.put(config, "webhook_secret", secret)
    end)
  end

  # --- Log Source threshold ---

  def handle_event(
        "update_log_threshold",
        %{"integration-id" => integration_id, "field" => field, "value" => value},
        socket
      )
      when field in ["error_threshold", "window_minutes"] do
    max = if field == "error_threshold", do: 100, else: 60

    case Integer.parse(value) do
      {int_value, _} when int_value > 0 ->
        update_integration_config(socket, integration_id, fn config ->
          Map.put(config, field, min(int_value, max))
        end)

      _ ->
        {:noreply, socket}
    end
  end

  # --- RSS Feed management ---

  def handle_event("add_rss_feed", %{"integration-id" => integration_id}, socket) do
    update_integration_config(socket, integration_id, fn config ->
      urls = config["feed_urls"] || []
      Map.put(config, "feed_urls", urls ++ [""])
    end)
  end

  def handle_event(
        "remove_rss_feed",
        %{"integration-id" => integration_id, "index" => index_str},
        socket
      ) do
    index = String.to_integer(index_str)

    update_integration_config(socket, integration_id, fn config ->
      urls = config["feed_urls"] || []
      Map.put(config, "feed_urls", List.delete_at(urls, index))
    end)
  end

  def handle_event(
        "update_rss_feed_url",
        %{"integration-id" => integration_id, "index" => index_str, "value" => value},
        socket
      ) do
    index = String.to_integer(index_str)

    update_integration_config(socket, integration_id, fn config ->
      urls = config["feed_urls"] || []
      Map.put(config, "feed_urls", List.replace_at(urls, index, value))
    end)
  end

  def handle_event(
        "update_rss_poll_interval",
        %{"integration-id" => integration_id, "value" => value},
        socket
      ) do
    case Integer.parse(value) do
      {interval, _} when interval >= 5 and interval <= 1440 ->
        update_integration_config(socket, integration_id, fn config ->
          Map.put(config, "poll_interval_minutes", interval)
        end)

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("sync_integration", %{"integration-id" => integration_id}, socket) do
    if Enum.any?(socket.assigns.integrations, &(&1.id == integration_id)) do
      case Magus.Integrations.Workers.PollDataSource.enqueue(integration_id) do
        {:ok, _job} ->
          {:noreply, put_flash(socket, :info, gettext("Sync queued"))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to queue sync"))}
      end
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info (forwarded from parent LiveView via send_update)
  # ---------------------------------------------------------------------------

  # These are sent by the wizard to the parent LiveView process.
  # The parent LiveView should forward them via send_update or the component
  # can handle them if the parent delegates.
  # Since LiveComponents don't receive handle_info directly, the parent
  # LiveView should handle these and call send_update.
  #
  # However, we provide public functions the parent can call:

  @doc """
  Call from the parent LiveView's handle_info to handle wizard completion.
  Returns the updated socket assigns map for send_update.
  """
  def wizard_complete do
    %{wizard_event: :complete}
  end

  @doc """
  Call from the parent LiveView's handle_info to handle wizard close.
  Returns the updated socket assigns map for send_update.
  """
  def wizard_closed do
    %{wizard_event: :closed}
  end

  # ---------------------------------------------------------------------------
  # Grouping
  # ---------------------------------------------------------------------------

  defp group_integrations(integrations, provider_meta) do
    integrations
    |> Enum.group_by(fn integration ->
      meta = Map.get(provider_meta, integration.provider_key)
      if meta, do: meta.source_type, else: :other
    end)
    |> Enum.sort_by(fn {type, _} ->
      case type do
        :channel -> 0
        :tool_provider -> 1
        :data_source -> 2
        _ -> 3
      end
    end)
  end

  defp source_type_label(:channel), do: gettext("Channels")
  defp source_type_label(:tool_provider), do: gettext("Tools")
  defp source_type_label(:data_source), do: gettext("Data Sources")
  defp source_type_label(_), do: gettext("Other")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp reload_integrations(socket) do
    integrations = load_integrations(socket.assigns.agent_id, socket.assigns.current_user)
    provider_meta = build_provider_meta()
    connected_provider_keys = Enum.map(integrations, & &1.provider_key)

    socket
    |> assign(:integrations, integrations)
    |> assign(:provider_meta, provider_meta)
    |> assign(:connected_provider_keys, connected_provider_keys)
  end

  defp load_integrations(agent_id, user) do
    case Integrations.list_agent_integrations(agent_id, actor: user) do
      {:ok, integrations} -> integrations
      _ -> []
    end
  end

  defp build_provider_meta do
    Integrations.list_available_providers()
    |> Map.new(fn provider ->
      {provider.key, provider}
    end)
  end

  defp disconnect_integration_impl(integration, provider_key, user) do
    provider_module = Integrations.get_provider_module(provider_key)

    # Load credential for cleanup
    case Ash.load(integration, [:credential], actor: user) do
      {:ok, %{credential: credential}} when not is_nil(credential) ->
        if provider_module && function_exported?(provider_module, :on_credentials_removed, 2) do
          provider_module.on_credentials_removed(integration, credential.encrypted_data || %{})
        end

        # Credential has no policies; authorize?: false is appropriate
        case Integrations.revoke_credential(credential, authorize?: false) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to revoke credential: #{inspect(reason)}")
        end

      _ ->
        :ok
    end

    case Ash.destroy(integration, actor: user) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to destroy integration: #{inspect(reason)}")
    end
  end

  defp update_integration_config(socket, integration_id, update_fn) do
    integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

    if integration do
      config = integration.config || %{}
      new_config = update_fn.(config)

      case Integrations.update_integration_config(
             integration,
             %{config: new_config},
             actor: socket.assigns.current_user
           ) do
        {:ok, _updated} ->
          {:noreply, reload_integrations(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update configuration"))}
      end
    else
      {:noreply, socket}
    end
  end

  defp provider_icon(key) when is_atom(key), do: Map.get(@provider_icons, key, "lucide-puzzle")
  defp provider_icon(_), do: "lucide-puzzle"
end
