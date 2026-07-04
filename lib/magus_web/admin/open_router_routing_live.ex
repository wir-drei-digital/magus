defmodule MagusWeb.Admin.OpenRouterRoutingLive do
  @moduledoc """
  Admin allow-list for OpenRouter upstream providers.

  Lists providers synced from `GET /api/v1/providers` with their advisory
  location data (headquarters/datacenters), lets an admin toggle each
  provider's `allowed` flag, and runs a one-shot sync via
  `Magus.Models.OpenRouterProviderSync`. Enforcement of the allow-list happens
  in the routing layer, not here. `headquarters`/`datacenters` are advisory
  only and never used for automatic enforcement.
  """
  use MagusWeb, :live_view

  require Logger

  alias Magus.Models
  alias Magus.Models.OpenRouterProviderSync
  alias MagusWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "OpenRouter Routing")
     |> assign(:current_path, "/admin/openrouter-routing")
     |> load_providers()}
  end

  defp load_providers(socket) do
    providers =
      Models.list_open_router_providers!(actor: socket.assigns.current_user)
      |> Enum.sort_by(& &1.slug)

    socket
    |> assign(:providers, providers)
    |> assign(:allowed_count, Enum.count(providers, & &1.allowed))
  end

  defp admin?(socket), do: socket.assigns.current_user.is_admin == true

  @impl true
  def handle_event("toggle_allow", %{"slug" => slug}, socket) do
    case Enum.find(socket.assigns.providers, &(&1.slug == slug)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Provider not found.")}

      provider ->
        case Models.set_open_router_provider_allowed(provider, !provider.allowed,
               actor: socket.assigns.current_user
             ) do
          {:ok, _} ->
            {:noreply, load_providers(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not update provider.")}
        end
    end
  end

  @impl true
  def handle_event("sync", _params, socket) do
    # The sync path bypasses Ash policies (authorize?: false), so guard admin
    # explicitly here rather than relying on the route on_mount alone.
    if admin?(socket) do
      case OpenRouterProviderSync.sync() do
        {:ok, %{synced: n}} ->
          {:noreply,
           socket
           |> put_flash(:info, "Synced #{n} providers from OpenRouter.")
           |> load_providers()}

        {:error, reason} ->
          Logger.warning("OpenRouter provider sync failed: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Sync failed. See logs.")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">OpenRouter routing</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Allow-list of OpenRouter upstream providers. Toggle which providers may serve requests.
            </p>
          </div>
          <button
            type="button"
            data-testid="or-sync-button"
            class="btn btn-primary btn-sm"
            phx-click="sync"
          >
            <.icon name="lucide-refresh-cw" class="w-4 h-4" /> Sync from OpenRouter
          </button>
        </div>

        <div data-testid="or-mode-banner" class="text-sm">
          <%= if @allowed_count == 0 do %>
            <span class="text-warning">
              No providers allowed yet. Toggle providers below to route requests to them.
            </span>
          <% else %>
            <span class="text-base-content/70">{@allowed_count} providers allowed.</span>
          <% end %>
        </div>

        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr class="bg-base-300/50">
                  <th class="text-center">Allowed</th>
                  <th>Name</th>
                  <th>Slug</th>
                  <th>HQ</th>
                  <th>Datacenters</th>
                  <th>Last synced</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@providers == []}>
                  <td colspan="6" class="text-center py-8 text-base-content/50">
                    No providers synced yet. Click "Sync from OpenRouter".
                  </td>
                </tr>
                <tr
                  :for={p <- @providers}
                  data-testid="or-provider-row"
                  class="hover:bg-base-300/30"
                >
                  <td class="text-center">
                    <input
                      type="checkbox"
                      class="toggle toggle-sm toggle-primary"
                      data-testid={"or-allow-toggle-#{p.slug}"}
                      checked={p.allowed}
                      phx-click="toggle_allow"
                      phx-value-slug={p.slug}
                    />
                  </td>
                  <td class="font-medium">{p.name}</td>
                  <td>
                    <code class="text-xs bg-base-300 px-1 py-0.5 rounded">{p.slug}</code>
                  </td>
                  <td class="text-base-content/70">{p.headquarters || "n/a"}</td>
                  <td class="text-base-content/70 text-xs">
                    {if p.datacenters == [], do: "n/a", else: Enum.join(p.datacenters, ", ")}
                  </td>
                  <td class="text-base-content/70 text-xs">
                    {if p.last_synced_at,
                      do: Calendar.strftime(p.last_synced_at, "%Y-%m-%d"),
                      else: "n/a"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end
end
