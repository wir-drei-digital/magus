defmodule MagusWeb.Admin.ProvidersLive do
  @moduledoc """
  Admin view for configuring LLM API providers and viewing their usage.

  Two sections:

  - **Configured providers** — CRUD over `Magus.Models.Provider` (Ash
    policy-enforced admin writes), per-provider connection tests
    (`Magus.Models.HealthCheck`), and a catalog/registry refresh
    (`Magus.Models.CatalogSync`). The stored `api_key` is encrypted at rest
    and is never rendered back into the page (not in lists, form values, or
    errors).
  - **Provider usage** — billing/usage snapshots from external providers.

  """
  use MagusWeb, :live_view

  require Ash.Query
  require Logger

  alias Magus.Agents.Providers.ProviderUsage
  alias Magus.Models.CatalogSync
  alias Magus.Models.HealthCheck
  alias Magus.Models.Provider
  alias MagusWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Providers")
      |> assign(:current_path, "/admin/providers")
      |> assign(:loading, true)
      |> assign(:provider_usage, [])
      |> assign(:provider, nil)
      |> assign(:form, nil)
      |> assign(:refreshing_registry, false)
      # ref of the in-flight registry refresh task, or nil
      |> assign(:registry_task, nil)
      # task ref -> provider id, for test_connection tasks
      |> assign(:health_tasks, %{})
      # provider id -> {:ok | :error, message}
      |> assign(:health_results, %{})
      |> assign(:req_llm_ids, req_llm_provider_options())
      |> load_providers()

    # Fetch usage data asynchronously
    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Providers")
    |> assign(:provider, nil)
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    form =
      Provider
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.current_user)
      |> to_form()

    socket
    |> assign(:page_title, "New Provider")
    |> assign(:provider, nil)
    |> assign(:form, form)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Ash.get(Provider, id, actor: socket.assigns.current_user) do
      {:ok, provider} ->
        form =
          provider
          |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
          |> to_form()

        socket
        |> assign(:page_title, "Edit #{provider.name}")
        |> assign(:provider, provider)
        |> assign(:form, form)

      {:error, _} ->
        socket
        |> put_flash(:error, "Provider not found")
        |> push_navigate(to: ~p"/admin/providers")
    end
  end

  defp load_providers(socket) do
    providers =
      Provider
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(actor: socket.assigns.current_user)
      |> Enum.map(fn provider ->
        # Compute key state server-side as a boolean — NEVER expose the key.
        Map.put(provider, :has_stored_key?, present_key?(provider.api_key))
      end)

    assign(socket, :providers, providers)
  end

  defp present_key?(key) when is_binary(key) and key != "", do: true
  defp present_key?(_), do: false

  # Runtime-configurable so tests can stub out the external billing-API fetches
  # (see `config :magus, :provider_usage_fetcher`). Defaults to the real module.
  defp usage_fetcher do
    Application.get_env(:magus, :provider_usage_fetcher, ProviderUsage)
  end

  @impl true
  def handle_info(:load_data, socket) do
    provider_usage = usage_fetcher().fetch_all()

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:provider_usage, provider_usage)

    {:noreply, socket}
  end

  # A connection-test task finished.
  def handle_info({ref, result}, socket) when is_map_key(socket.assigns.health_tasks, ref) do
    Process.demonitor(ref, [:flush])
    {provider_id, tasks} = Map.pop(socket.assigns.health_tasks, ref)
    results = Map.put(socket.assigns.health_results, provider_id, normalize_health(result))

    {:noreply,
     socket
     |> assign(:health_tasks, tasks)
     |> assign(:health_results, results)}
  end

  # A connection-test task crashed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_map_key(socket.assigns.health_tasks, ref) do
    {provider_id, tasks} = Map.pop(socket.assigns.health_tasks, ref)

    results =
      Map.put(
        socket.assigns.health_results,
        provider_id,
        {:error, "test crashed: #{inspect(reason)}"}
      )

    {:noreply,
     socket
     |> assign(:health_tasks, tasks)
     |> assign(:health_results, results)}
  end

  # Registry refresh task finished.
  def handle_info({ref, result}, socket) when ref == socket.assigns.registry_task do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        :ok ->
          put_flash(socket, :info, "Registry refreshed")

        {:error, reason} ->
          put_flash(socket, :error, "Registry refresh failed: #{inspect(reason)}")

        other ->
          put_flash(socket, :error, "Registry refresh failed: #{inspect(other)}")
      end

    {:noreply,
     socket
     |> assign(:registry_task, nil)
     |> assign(:refreshing_registry, false)}
  end

  # Registry refresh task crashed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when ref == socket.assigns.registry_task do
    {:noreply,
     socket
     |> put_flash(:error, "Registry refresh failed: #{inspect(reason)}")
     |> assign(:registry_task, nil)
     |> assign(:refreshing_registry, false)}
  end

  # Stray task message we don't track — ignore.
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) when is_reference(ref) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket = assign(socket, :loading, true)
    send(self(), :load_data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    # On update, a blank api_key must PRESERVE the stored key rather than
    # overwrite it with "". Strip blank api_key from the params before submit.
    params = strip_blank_api_key(params)

    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _provider} ->
        action = if socket.assigns.live_action == :new, do: "created", else: "updated"

        {:noreply,
         socket
         |> put_flash(:info, "Provider #{action} successfully")
         |> push_navigate(to: ~p"/admin/providers")}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    with {:ok, provider} <- Ash.get(Provider, id, actor: socket.assigns.current_user),
         {:ok, _} <-
           provider
           |> Ash.Changeset.for_update(:update, %{enabled?: !provider.enabled?},
             actor: socket.assigns.current_user
           )
           |> Ash.update() do
      {:noreply,
       socket
       |> put_flash(:info, "Provider #{if provider.enabled?, do: "disabled", else: "enabled"}")
       |> load_providers()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to update provider")}
    end
  end

  @impl true
  def handle_event("test_connection", %{"id" => id}, socket) do
    # Non-Ash side effect: explicitly guard admin, not just the route on_mount.
    if admin?(socket) do
      case Ash.get(Provider, id, actor: socket.assigns.current_user) do
        {:ok, provider} ->
          # async_nolink so a raise inside test_provider (e.g. a transport or
          # decoding crash) surfaces as a :DOWN we handle, instead of taking
          # the LiveView down with it.
          task =
            Task.Supervisor.async_nolink(Magus.AgentLoopTaskSupervisor, fn ->
              result = HealthCheck.test_provider(provider)
              # Operator visibility: surface credential/endpoint failures in the
              # logs, not just the admin UI. The health-check message never
              # contains the api_key (see HealthCheck), so this logs no secret.
              with {:error, msg} <- result do
                Logger.warning("Provider health check failed for #{provider.slug}: #{msg}")
              end

              result
            end)

          socket =
            socket
            |> update(:health_tasks, &Map.put(&1, task.ref, provider.id))
            |> update(:health_results, &Map.delete(&1, provider.id))

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Provider not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("refresh_registry", _params, socket) do
    # Non-Ash side effect: explicitly guard admin.
    if admin?(socket) do
      # Route through CatalogSync.Server so this manual refresh serializes with
      # write-triggered reloads (LLMDB.load swaps the whole catalog). The Server
      # runs the guarded reload, so a malformed snapshot returns {:error, reason}
      # rather than raising. async_nolink keeps the LiveView responsive during
      # the network fetch + load; the result arrives via {ref, result} (tracked
      # in :registry_task) and a crash arrives as :DOWN — both already handled.
      task =
        Task.Supervisor.async_nolink(Magus.AgentLoopTaskSupervisor, fn ->
          CatalogSync.Server.refresh({:github_releases, ref: :latest})
        end)

      {:noreply,
       socket
       |> assign(:registry_task, task.ref)
       |> assign(:refreshing_registry, true)}
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  defp admin?(socket), do: socket.assigns.current_user.is_admin == true

  # Drop a blank api_key so the update doesn't clobber the stored value.
  defp strip_blank_api_key(params) when is_map(params) do
    case Map.get(params, "api_key") do
      key when is_binary(key) ->
        if String.trim(key) == "", do: Map.delete(params, "api_key"), else: params

      _ ->
        params
    end
  end

  defp normalize_health({:ok, %{models: n}}), do: {:ok, "ok: #{n} models"}
  defp normalize_health({:error, msg}) when is_binary(msg), do: {:error, msg}
  defp normalize_health(other), do: {:error, "unexpected result: #{inspect(other)}"}

  # "openai_compatible" first, then all ReqLLM provider ids (sorted).
  defp req_llm_provider_options do
    others =
      ReqLLM.Providers.list()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == "openai_compatible"))
      |> Enum.sort()

    ["openai_compatible" | others]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-10">
        <.configured_providers
          providers={@providers}
          health_results={@health_results}
          health_tasks={@health_tasks}
          refreshing_registry={@refreshing_registry}
        />

        <%!-- ============ Provider Usage ============ --%>
        <div class="space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-xl font-bold text-base-content">Provider usage</h2>
              <p class="text-base-content/60 text-sm mt-1">
                Billing and usage information from external providers
              </p>
            </div>
            <button
              type="button"
              phx-click="refresh"
              disabled={@loading}
              class="btn btn-outline btn-sm"
            >
              <.icon name="lucide-refresh-cw" class={["w-4 h-4", @loading && "animate-spin"]} />
              Refresh
            </button>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%= if @loading do %>
              <.provider_skeleton />
              <.provider_skeleton />
              <.provider_skeleton />
              <.provider_skeleton />
            <% else %>
              <%= for usage <- @provider_usage do %>
                <.provider_card usage={usage} />
              <% end %>
            <% end %>
          </div>
        </div>

        <.provider_form_modal
          form={@form}
          live_action={@live_action}
          provider={@provider}
          req_llm_ids={@req_llm_ids}
        />
      </div>
    </Layouts.admin>
    """
  end

  attr :providers, :list, required: true
  attr :health_results, :map, required: true
  attr :health_tasks, :map, required: true
  attr :refreshing_registry, :boolean, required: true

  defp configured_providers(assigns) do
    ~H"""
    <%!-- ============ Configured Providers ============ --%>
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Configured providers</h1>
          <p class="text-base-content/60 text-sm mt-1">
            LLM API endpoints and instance-level credentials
          </p>
        </div>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="refresh_registry"
            data-test-refresh-registry
            disabled={@refreshing_registry}
            class="btn btn-ghost btn-sm"
          >
            <.icon
              name="lucide-refresh-cw"
              class={["w-4 h-4", @refreshing_registry && "animate-spin"]}
            /> Refresh registry
          </button>
          <.link navigate={~p"/admin/providers/new"} class="btn btn-primary btn-sm">
            <.icon name="lucide-plus" class="w-4 h-4" /> Add Provider
          </.link>
        </div>
      </div>

      <div class="card bg-base-200 border border-base-300 overflow-hidden">
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="bg-base-300/50">
                <th>Name</th>
                <th>Slug</th>
                <th>ReqLLM ID</th>
                <th>Base URL</th>
                <th class="text-center">Key</th>
                <th class="text-center">Status</th>
                <th class="text-center">Test</th>
                <th class="text-center">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@providers == []}>
                <td colspan="8" class="text-center py-8 text-base-content/50">
                  No providers configured
                </td>
              </tr>
              <tr
                :for={provider <- @providers}
                data-test-provider={provider.slug}
                class="hover:bg-base-300/30"
              >
                <td class="font-medium">{provider.name}</td>
                <td>
                  <code class="text-xs bg-base-300 px-1 py-0.5 rounded">{provider.slug}</code>
                </td>
                <td class="text-base-content/70">{provider.req_llm_id}</td>
                <td class="text-base-content/70 text-xs">
                  {provider.base_url || "ReqLLM default"}
                </td>
                <td class="text-center">
                  <%= if provider.has_stored_key? do %>
                    <span class="badge badge-success badge-sm">stored</span>
                  <% else %>
                    <span class="badge badge-ghost badge-sm">from env</span>
                  <% end %>
                </td>
                <td class="text-center">
                  <button
                    type="button"
                    phx-click="toggle_enabled"
                    phx-value-id={provider.id}
                    data-test-toggle={provider.slug}
                    class="cursor-pointer"
                    title={if provider.enabled?, do: "Disable", else: "Enable"}
                  >
                    <%= if provider.enabled? do %>
                      <span class="badge badge-success badge-sm">enabled</span>
                    <% else %>
                      <span class="badge badge-ghost badge-sm">disabled</span>
                    <% end %>
                  </button>
                </td>
                <td class="text-center text-xs" data-test-health={provider.slug}>
                  <%= case @health_results[provider.id] do %>
                    <% {:ok, msg} -> %>
                      <span class="text-success">{msg}</span>
                    <% {:error, msg} -> %>
                      <span class="text-error">{msg}</span>
                    <% _ -> %>
                      <%= if provider.id in Map.values(@health_tasks) do %>
                        <span class="text-base-content/50">testing…</span>
                      <% else %>
                        <span class="text-base-content/30">—</span>
                      <% end %>
                  <% end %>
                </td>
                <td>
                  <div class="flex items-center justify-center gap-1">
                    <.link
                      navigate={~p"/admin/providers/#{provider.id}/edit"}
                      class="btn btn-ghost btn-xs"
                      title="Edit"
                    >
                      <.icon name="lucide-pencil" class="w-4 h-4" />
                    </.link>
                    <button
                      type="button"
                      phx-click="test_connection"
                      phx-value-id={provider.id}
                      data-test-connection={provider.slug}
                      class="btn btn-ghost btn-xs"
                      title="Test connection"
                    >
                      <.icon name="lucide-plug-zap" class="w-4 h-4" />
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :live_action, :atom, required: true
  attr :provider, :any, required: true
  attr :req_llm_ids, :list, required: true

  defp provider_form_modal(assigns) do
    ~H"""
    <%!-- ============ Create / Edit Modal ============ --%>
    <.modal
      :if={@form}
      id="provider-modal"
      show={@live_action in [:new, :edit]}
      on_close={JS.navigate(~p"/admin/providers")}
      size={:lg}
    >
      <:title>{if @live_action == :new, do: "Add Provider", else: "Edit Provider"}</:title>

      <.form
        for={@form}
        id="provider-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input field={@form[:name]} label="Name" placeholder="e.g., OpenRouter" />

        <%= if @live_action == :new do %>
          <.input
            field={@form[:slug]}
            label="Slug"
            placeholder="e.g., openrouter or local_vllm"
          />
          <div>
            <.input
              field={@form[:req_llm_id]}
              type="select"
              label="ReqLLM provider"
              options={@req_llm_ids}
            />
            <p class="text-xs text-base-content/50 mt-1">
              Choose <code>openai_compatible</code> for a custom endpoint (requires a base URL).
            </p>
          </div>
        <% end %>

        <.input
          field={@form[:base_url]}
          label="Base URL"
          placeholder="ReqLLM default (leave blank) or e.g. http://localhost:8000/v1"
        />

        <div>
          <.input
            field={@form[:api_key]}
            type="password"
            value=""
            label="API key"
            autocomplete="off"
            placeholder={
              if (@live_action == :edit and @provider) && present_key?(@provider.api_key),
                do: "•••• stored",
                else: "Stored encrypted; blank uses the provider env var"
            }
          />
          <p :if={@live_action == :edit} class="text-xs text-base-content/50 mt-1">
            Leave blank to keep the stored key.
          </p>
        </div>

        <.input type="checkbox" field={@form[:enabled?]} label="Enabled" />

        <div class="flex items-center justify-end gap-3 pt-4 border-t border-base-300">
          <.link navigate={~p"/admin/providers"} class="btn btn-ghost btn-sm">Cancel</.link>
          <button type="submit" class="btn btn-primary btn-sm">
            {if @live_action == :new, do: "Create Provider", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  attr :usage, :map, required: true

  defp provider_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div class="flex items-center gap-3">
            <div class={["p-2 rounded-lg", provider_bg(@usage.provider)]}>
              <.icon name={provider_icon(@usage.provider)} class="w-5 h-5" />
            </div>
            <div>
              <h3 class="font-semibold text-base-content">
                {ProviderUsage.provider_name(@usage.provider)}
              </h3>
              <p class="text-xs text-base-content/50">
                Updated {format_time(@usage.last_updated)}
              </p>
              <p :if={@usage.note} class="text-xs text-base-content/40 mt-0.5">
                {@usage.note}
              </p>
            </div>
          </div>
          <a
            :if={ProviderUsage.billing_url(@usage.provider)}
            href={ProviderUsage.billing_url(@usage.provider)}
            target="_blank"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="lucide-external-link" class="w-4 h-4" />
          </a>
        </div>

        <div class="mt-4">
          <%= if @usage.error do %>
            <div class="flex items-center gap-2 text-warning">
              <.icon name="lucide-triangle-alert" class="w-4 h-4" />
              <span class="text-sm">{@usage.error}</span>
            </div>
          <% else %>
            <div class="grid grid-cols-2 gap-3">
              <%= if @usage.balance do %>
                <div class="stat bg-base-300/50 rounded-lg p-3">
                  <div class="stat-title text-xs">
                    {if @usage.provider == :aimlapi, do: "Provider units", else: "Balance"}
                  </div>
                  <div class="stat-value text-lg text-success">
                    {format_value(@usage.balance, @usage.provider)}
                  </div>
                </div>
              <% end %>
              <%= if @usage.total_usage do %>
                <div class="stat bg-base-300/50 rounded-lg p-3">
                  <div class="stat-title text-xs">Usage</div>
                  <div class="stat-value text-lg text-error">
                    {format_cost(@usage.total_usage)}
                  </div>
                </div>
              <% end %>
            </div>

            <%= if @usage.cost_breakdown && @usage.cost_breakdown != [] do %>
              <div class="mt-3 text-xs text-base-content/60">
                <details>
                  <summary class="cursor-pointer hover:text-base-content">
                    Cost breakdown ({length(@usage.cost_breakdown)} items)
                  </summary>
                  <ul class="mt-2 space-y-1 pl-4">
                    <%= for item <- @usage.cost_breakdown do %>
                      <li class="flex justify-between">
                        <span>{item["price_name"] || item["price_id"]}</span>
                        <span class="font-mono">${item["amount_usd"]}</span>
                      </li>
                    <% end %>
                  </ul>
                </details>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp provider_skeleton(assigns) do
    assigns = assign(assigns, :class, "")

    ~H"""
    <div class="card bg-base-200 border border-base-300 animate-pulse">
      <div class="card-body p-4">
        <div class="flex items-center gap-3">
          <div class="w-9 h-9 bg-base-300 rounded-lg"></div>
          <div class="space-y-2">
            <div class="h-4 w-24 bg-base-300 rounded"></div>
            <div class="h-3 w-16 bg-base-300 rounded"></div>
          </div>
        </div>
        <div class="mt-4 grid grid-cols-2 gap-3">
          <div class="h-16 bg-base-300/50 rounded-lg"></div>
          <div class="h-16 bg-base-300/50 rounded-lg"></div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_icon(:openrouter), do: "lucide-cpu"
  defp provider_icon(:exa), do: "lucide-search"
  defp provider_icon(:aimlapi), do: "lucide-film"
  defp provider_icon(:publicai), do: "lucide-globe"
  defp provider_icon(:fal), do: "lucide-film"
  defp provider_icon(_), do: "lucide-box"

  defp provider_bg(:openrouter), do: "bg-primary/10 text-primary"
  defp provider_bg(:exa), do: "bg-secondary/10 text-secondary"
  defp provider_bg(:aimlapi), do: "bg-accent/10 text-accent"
  defp provider_bg(:publicai), do: "bg-info/10 text-info"
  defp provider_bg(:fal), do: "bg-warning/10 text-warning"
  defp provider_bg(_), do: "bg-base-300 text-base-content"

  defp format_cost(nil), do: "$0.00"

  defp format_cost(decimal) do
    "$" <> (decimal |> Decimal.round(4) |> Decimal.to_string())
  end

  # Format value based on provider (some use provider units, others use dollars)
  defp format_value(nil, _provider), do: "0"

  defp format_value(decimal, :aimlapi) do
    # AIML API uses provider units, not dollars
    decimal |> Decimal.round(2) |> Decimal.to_string()
  end

  defp format_value(decimal, _provider) do
    # Default: format as currency
    format_cost(decimal)
  end

  defp format_time(nil), do: "unknown"

  defp format_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end
end
