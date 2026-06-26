defmodule MagusWeb.AgentsLive.Components.IntegrationCard do
  @moduledoc """
  Function component that renders a single connected integration as an
  expandable card (collapsed summary + expanded provider-specific details).
  """

  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext
  import MagusWeb.CoreComponents

  alias Phoenix.LiveView.JS

  # ---------------------------------------------------------------------------
  # Integration Card
  # ---------------------------------------------------------------------------

  @doc """
  Renders an integration card with collapsed/expanded states.

  ## Attributes

    * `:integration` - UserIntegration struct (required)
    * `:provider_meta` - Map with `:name`, `:source_type`, `:has_tools` (required)
    * `:icon` - Lucide icon name string (required)
    * `:expanded` - Whether the card is expanded (required)
    * `:target` - Parent LiveComponent's `@myself` for phx-target (required)
  """
  attr :integration, :map, required: true
  attr :provider_meta, :map, required: true
  attr :icon, :string, required: true
  attr :expanded, :boolean, required: true
  attr :target, :any, required: true
  attr :regenerated_api_key, :string, default: nil

  def integration_card(assigns) do
    config = assigns.integration.config || %{}

    assigns =
      assigns
      |> assign(:config, config)
      |> assign(:summary, integration_summary(assigns.integration, assigns.provider_meta))
      |> assign(:badge_class, status_badge_class(assigns.integration.status))
      |> assign(:badge_label, status_label(assigns.integration.status))
      |> assign(:pending_approvals, get_config(config, "pending_approvals") || [])
      |> assign(:allowed_chat_ids, get_config(config, "allowed_chat_ids") || [])

    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300">
      <%!-- Collapsed header (always visible) --%>
      <div
        class="flex items-center gap-3 px-4 py-3 cursor-pointer select-none"
        phx-click="toggle_expand"
        phx-value-id={@integration.id}
        phx-target={@target}
      >
        <div class="w-9 h-9 rounded-lg bg-primary/10 flex items-center justify-center shrink-0">
          <.icon name={@icon} class="w-4.5 h-4.5 text-primary" />
        </div>

        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between">
            <h3 class="font-medium text-sm text-base-content">{@provider_meta.name}</h3>
            <span class={["badge badge-sm", @badge_class]}>{@badge_label}</span>
          </div>
          <p class="text-xs text-base-content/50 truncate">{@summary}</p>
        </div>

        <.icon
          name={if @expanded, do: "lucide-chevron-down", else: "lucide-chevron-right"}
          class="w-4 h-4 text-base-content/40 shrink-0"
        />
      </div>

      <%!-- Expanded details --%>
      <div :if={@expanded} class="border-t border-base-300 px-4 py-3 space-y-4">
        <.provider_details
          integration={@integration}
          config={@config}
          pending_approvals={@pending_approvals}
          allowed_chat_ids={@allowed_chat_ids}
          target={@target}
          regenerated_api_key={@regenerated_api_key}
        />

        <%!-- Footer --%>
        <div class="border-t border-base-300 pt-3">
          <button
            type="button"
            phx-click="disconnect_integration"
            phx-value-id={@integration.id}
            phx-target={@target}
            data-confirm={gettext("Are you sure you want to disconnect this integration?")}
            class="btn btn-ghost btn-sm text-error"
          >
            <.icon name="lucide-unplug" class="w-3.5 h-3.5" />
            {gettext("Disconnect")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Provider-specific details
  # ---------------------------------------------------------------------------

  attr :integration, :map, required: true
  attr :config, :map, required: true
  attr :pending_approvals, :list, required: true
  attr :allowed_chat_ids, :list, required: true
  attr :target, :any, required: true
  attr :regenerated_api_key, :string, default: nil

  defp provider_details(%{integration: %{provider_key: :telegram}} = assigns) do
    bot_username = get_config(assigns.config, "bot_username")
    assigns = assign(assigns, :bot_username, bot_username)

    ~H"""
    <%!-- Bot username --%>
    <div class="flex items-center gap-2">
      <.icon name="lucide-bot" class="w-4 h-4 text-base-content/40" />
      <span class="text-sm text-base-content">
        {gettext("Bot:")}
        <span :if={@bot_username} class="font-medium">@{@bot_username}</span>
        <span :if={!@bot_username} class="text-base-content/50 italic">{gettext("Unknown")}</span>
      </span>
    </div>

    <%!-- Allowed chats --%>
    <div :if={@allowed_chat_ids != []}>
      <p class="text-sm font-medium mb-2 flex items-center gap-1.5">
        <.icon name="lucide-shield-check" class="w-4 h-4 text-success" />
        {gettext("Allowed Chats")}
      </p>
      <div class="flex flex-wrap gap-2">
        <div :for={chat_id <- @allowed_chat_ids} class="badge badge-outline gap-1">
          {chat_id}
          <button
            type="button"
            phx-click="remove_chat"
            phx-value-integration-id={@integration.id}
            phx-value-chat-id={chat_id}
            phx-target={@target}
            class="hover:text-error"
            title={gettext("Remove")}
          >
            <.icon name="lucide-x" class="w-3 h-3" />
          </button>
        </div>
      </div>
    </div>

    <%!-- Pending approvals --%>
    <div :if={@pending_approvals != []}>
      <p class="text-sm font-medium mb-2 flex items-center gap-1.5">
        <.icon name="lucide-clock" class="w-4 h-4 text-warning" />
        {gettext("Pending Approvals")}
        <span class="badge badge-sm badge-warning">{length(@pending_approvals)}</span>
      </p>
      <div class="space-y-2">
        <div
          :for={entry <- @pending_approvals}
          class="flex items-center justify-between p-2.5 bg-base-200 rounded-lg"
        >
          <div>
            <p class="text-sm font-medium">
              {entry["sender_name"] || gettext("Unknown")}
              <span :if={entry["sender_username"]} class="text-xs text-base-content/50">
                @{entry["sender_username"]}
              </span>
            </p>
            <p class="text-xs text-base-content/40">
              {gettext("Chat ID: %{id}", id: entry["chat_id"])}
            </p>
          </div>
          <div class="flex gap-1">
            <button
              type="button"
              phx-click="approve_chat"
              phx-value-integration-id={@integration.id}
              phx-value-chat-id={entry["chat_id"]}
              phx-target={@target}
              class="btn btn-xs btn-success btn-outline"
              title={gettext("Approve")}
            >
              <.icon name="lucide-check" class="w-3 h-3" />
            </button>
            <button
              type="button"
              phx-click="deny_chat"
              phx-value-integration-id={@integration.id}
              phx-value-chat-id={entry["chat_id"]}
              phx-target={@target}
              class="btn btn-xs btn-error btn-outline"
              title={gettext("Deny")}
            >
              <.icon name="lucide-x" class="w-3 h-3" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_details(%{integration: %{provider_key: :api}} = assigns) do
    assigns = assign(assigns, :show_new_key, assigns.regenerated_api_key != nil)

    ~H"""
    <div class="space-y-3">
      <%!-- Regenerated key reveal --%>
      <div :if={@show_new_key} class="bg-base-200 rounded-lg p-4 space-y-3">
        <div class="flex items-center gap-2">
          <.icon name="lucide-check-circle" class="size-4 text-success" />
          <span class="text-sm font-medium">{gettext("New API key generated")}</span>
        </div>

        <div class="flex items-center gap-2">
          <code
            id="regenerated-api-key"
            class="flex-1 text-sm font-mono bg-base-300 rounded px-3 py-2 break-all select-all"
          >
            {@regenerated_api_key}
          </code>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square shrink-0"
            phx-click={JS.dispatch("phx:copy", to: "#regenerated-api-key")}
            title={gettext("Copy to clipboard")}
          >
            <.icon name="lucide-copy" class="size-4" />
          </button>
        </div>

        <div class="flex items-start gap-2 rounded-lg bg-warning/10 p-2.5 text-xs">
          <.icon name="lucide-alert-triangle" class="size-3.5 text-warning shrink-0 mt-0.5" />
          <p class="text-base-content/70">
            {gettext("Copy this key now. It won't be shown again.")}
          </p>
        </div>

        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="dismiss_regenerated_key"
          phx-target={@target}
        >
          {gettext("Dismiss")}
        </button>
      </div>

      <%!-- Key status --%>
      <div :if={!@show_new_key} class="flex items-center gap-2">
        <.icon name="lucide-key" class="w-4 h-4 text-base-content/40" />
        <span class="text-sm text-base-content">{gettext("API key configured")}</span>
      </div>

      <div class="flex items-start gap-2 rounded-lg bg-info/10 p-3 text-sm">
        <.icon name="lucide-info" class="size-4 text-info shrink-0 mt-0.5" />
        <p class="text-base-content/70">
          {gettext(
            "Send messages to your agent via POST /api/v1/messages with your API key as a Bearer token."
          )}
        </p>
      </div>

      <div>
        <button
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="regenerate_api_key"
          phx-value-integration-id={@integration.id}
          phx-target={@target}
          data-confirm={
            gettext(
              "This will invalidate the current API key. Any applications using it will stop working. Continue?"
            )
          }
        >
          <.icon name="lucide-refresh-cw" class="w-3.5 h-3.5" />
          {gettext("Regenerate API Key")}
        </button>
      </div>
    </div>
    """
  end

  defp provider_details(%{integration: %{provider_key: :google_calendar}} = assigns) do
    enabled_tools = assigns.integration.enabled_tools || []
    assigns = assign(assigns, :enabled_tools, enabled_tools)

    ~H"""
    <div>
      <p class="text-sm font-medium mb-2 flex items-center gap-1.5">
        <.icon name="lucide-wrench" class="w-4 h-4 text-base-content/50" />
        {gettext("Enabled Tools")}
      </p>
      <div :if={@enabled_tools != []} class="flex flex-wrap gap-2">
        <span :for={tool <- @enabled_tools} class="badge badge-outline badge-sm">
          {tool}
        </span>
      </div>
      <p :if={@enabled_tools == []} class="text-xs text-base-content/50 italic">
        {gettext("No tools enabled")}
      </p>
    </div>
    """
  end

  defp provider_details(%{integration: %{provider_key: :rss_source}} = assigns) do
    feed_urls = get_config(assigns.config, "feed_urls") || []

    poll_interval = get_config(assigns.config, "poll_interval_minutes") || 60

    assigns =
      assigns
      |> assign(:feed_urls, feed_urls)
      |> assign(:poll_interval, poll_interval)

    ~H"""
    <div class="space-y-4">
      <div>
        <div class="flex items-center justify-between mb-2">
          <span class="text-xs font-medium text-base-content/60 uppercase tracking-wider">
            {gettext("Feed URLs")}
          </span>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="add_rss_feed"
            phx-value-integration-id={@integration.id}
            phx-target={@target}
          >
            <.icon name="lucide-plus" class="w-3 h-3" />
            {gettext("Add")}
          </button>
        </div>

        <div :if={@feed_urls == []} class="text-sm text-base-content/40 py-2">
          {gettext("No feeds configured. Add a feed URL to start polling.")}
        </div>

        <div class="space-y-2">
          <div :for={{url, idx} <- Enum.with_index(@feed_urls)} class="flex gap-2 items-center group">
            <input
              type="url"
              value={url}
              placeholder="https://example.com/feed.xml"
              class="input input-bordered input-sm w-full font-mono text-xs"
              phx-blur="update_rss_feed_url"
              phx-value-integration-id={@integration.id}
              phx-value-index={idx}
              phx-target={@target}
              name={"feed_url_#{idx}"}
            />
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error opacity-0 group-hover:opacity-100"
              phx-click="remove_rss_feed"
              phx-value-integration-id={@integration.id}
              phx-value-index={idx}
              phx-target={@target}
            >
              <.icon name="lucide-x" class="w-3 h-3" />
            </button>
          </div>
        </div>
      </div>

      <div>
        <label class="label">
          <span class="label-text text-xs">{gettext("Poll interval (minutes)")}</span>
        </label>
        <input
          type="number"
          value={@poll_interval}
          min="5"
          max="1440"
          class="input input-bordered input-sm w-32"
          phx-blur="update_rss_poll_interval"
          phx-value-integration-id={@integration.id}
          phx-target={@target}
          name="poll_interval"
        />
      </div>

      <div class="flex items-center justify-between">
        <div :if={@integration.last_sync_at} class="flex items-center gap-1.5">
          <.icon name="lucide-clock" class="w-3.5 h-3.5 text-base-content/30" />
          <span class="text-xs text-base-content/40">
            {gettext("Last sync: %{time}", time: format_datetime(@integration.last_sync_at))}
          </span>
        </div>
        <div :if={!@integration.last_sync_at} class="text-xs text-base-content/40">
          {gettext("Never synced")}
        </div>
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="sync_integration"
          phx-value-integration-id={@integration.id}
          phx-target={@target}
        >
          <.icon name="lucide-refresh-cw" class="w-3 h-3" />
          {gettext("Sync now")}
        </button>
      </div>
    </div>
    """
  end

  defp provider_details(%{integration: %{provider_key: :log_source}} = assigns) do
    webhook_url =
      "#{Magus.Endpoint.url()}/webhooks/log_source/#{assigns.integration.id}"

    webhook_secret = get_config(assigns.config, "webhook_secret")

    assigns =
      assigns
      |> assign(:webhook_url, webhook_url)
      |> assign(:webhook_secret, webhook_secret)
      |> assign(:error_threshold, get_config(assigns.config, "error_threshold") || 5)
      |> assign(:window_minutes, get_config(assigns.config, "window_minutes") || 5)

    ~H"""
    <div class="space-y-4">
      <div>
        <label class="label"><span class="label-text text-xs">{gettext("Webhook URL")}</span></label>
        <div class="flex gap-2">
          <input
            type="text"
            value={@webhook_url}
            class="input input-bordered input-sm w-full font-mono text-xs"
            readonly
          />
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="copy_to_clipboard"
            phx-value-text={@webhook_url}
            phx-target={@target}
            title={gettext("Copy")}
          >
            <.icon name="lucide-copy" class="w-4 h-4" />
          </button>
        </div>
        <p class="text-xs text-base-content/50 mt-1">
          {gettext("POST JSON to this URL to ingest log entries.")}
        </p>
      </div>

      <div>
        <div class="flex items-center justify-between">
          <label class="label">
            <span class="label-text text-xs">{gettext("Webhook Secret")}</span>
          </label>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="regenerate_log_secret"
            phx-value-integration-id={@integration.id}
            phx-target={@target}
          >
            <.icon name="lucide-refresh-cw" class="w-3 h-3" />
            {if @webhook_secret, do: gettext("Regenerate"), else: gettext("Generate")}
          </button>
        </div>
        <div :if={@webhook_secret} class="flex gap-1">
          <input
            type="password"
            value={@webhook_secret}
            class="input input-bordered input-sm w-full font-mono text-xs"
            id={"log-secret-#{@integration.id}"}
            readonly
          />
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="copy_to_clipboard"
            phx-value-text={@webhook_secret}
            phx-target={@target}
            title={gettext("Copy")}
          >
            <.icon name="lucide-copy" class="w-4 h-4" />
          </button>
        </div>
        <p :if={!@webhook_secret} class="text-sm text-warning">
          {gettext(
            "No secret configured. Endpoint is unauthenticated. Generate a secret to secure it."
          )}
        </p>
        <p :if={@webhook_secret} class="text-xs text-base-content/50 mt-1">
          {gettext("Include as X-API-Key header for authentication.")}
        </p>
      </div>

      <div>
        <p class="text-xs font-medium text-base-content/60 uppercase tracking-wider mb-2">
          {gettext("Alert Threshold")}
        </p>
        <div class="flex gap-4">
          <div>
            <.input
              type="number"
              name="error_threshold"
              value={@error_threshold}
              min="1"
              max="100"
              label={gettext("Error count")}
              phx-blur="update_log_threshold"
              phx-value-integration-id={@integration.id}
              phx-value-field="error_threshold"
              phx-target={@target}
              class="input input-bordered input-sm w-32"
            />
          </div>
          <div>
            <.input
              type="number"
              name="window_minutes"
              value={@window_minutes}
              min="1"
              max="60"
              label={gettext("Window (minutes)")}
              phx-blur="update_log_threshold"
              phx-value-integration-id={@integration.id}
              phx-value-field="window_minutes"
              phx-target={@target}
              class="input input-bordered input-sm w-32"
            />
          </div>
        </div>
        <p class="text-xs text-base-content/50 mt-1">
          {gettext("Create inbox event when error count reaches threshold within the time window.")}
        </p>
      </div>

      <.last_sync_info integration={@integration} />
    </div>
    """
  end

  defp provider_details(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon name="lucide-info" class="w-4 h-4 text-base-content/40" />
      <span class="text-sm text-base-content/60">{gettext("Integration active")}</span>
    </div>
    <.last_sync_info integration={@integration} />
    """
  end

  # ---------------------------------------------------------------------------
  # Shared sub-components
  # ---------------------------------------------------------------------------

  attr :integration, :map, required: true

  defp last_sync_info(assigns) do
    ~H"""
    <div :if={@integration.last_sync_at} class="flex items-center gap-1.5">
      <.icon name="lucide-clock" class="w-3.5 h-3.5 text-base-content/30" />
      <span class="text-xs text-base-content/40">
        {gettext("Last sync: %{time}", time: format_datetime(@integration.last_sync_at))}
      </span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp status_badge_class(:active), do: "badge-success"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(:disabled), do: "badge-ghost"
  defp status_badge_class(:pending), do: "badge-warning"
  defp status_badge_class(_), do: "badge-ghost"

  defp status_label(:active), do: gettext("Active")
  defp status_label(:error), do: gettext("Error")
  defp status_label(:disabled), do: gettext("Disabled")
  defp status_label(:pending), do: gettext("Pending")
  defp status_label(_), do: gettext("Unknown")

  defp integration_summary(integration, provider_meta) do
    config = integration.config || %{}

    case integration.provider_key do
      :telegram ->
        bot = get_config(config, "bot_username")
        chats = get_config(config, "allowed_chat_ids") || []
        count = length(chats)

        if bot do
          "@#{bot} · #{ngettext("%{count} allowed chat", "%{count} allowed chats", count, count: count)}"
        else
          ngettext("%{count} allowed chat", "%{count} allowed chats", count, count: count)
        end

      :api ->
        gettext("REST API channel")

      :google_calendar ->
        tools = integration.enabled_tools || []
        count = length(tools)
        ngettext("%{count} tool enabled", "%{count} tools enabled", count, count: count)

      :rss_source ->
        feed_url = get_config(config, "feed_url") || gettext("No feed URL")
        last_sync = format_last_sync(integration.last_sync_at)
        if last_sync, do: "#{feed_url} · #{last_sync}", else: feed_url

      :log_source ->
        last_sync = format_last_sync(integration.last_sync_at)
        base = gettext("Webhook endpoint")
        if last_sync, do: "#{base} · #{last_sync}", else: base

      _ ->
        provider_meta[:source_type] || to_string(integration.provider_key)
    end
  end

  defp get_config(config, key) when is_map(config) do
    Map.get(config, key) || Map.get(config, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp get_config(_, _), do: nil

  defp format_last_sync(nil), do: nil

  defp format_last_sync(datetime) do
    gettext("synced %{time}", time: format_datetime(datetime))
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %H:%M")
  end
end
