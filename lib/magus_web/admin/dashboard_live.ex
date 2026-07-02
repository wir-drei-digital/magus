defmodule MagusWeb.Admin.DashboardLive do
  @moduledoc """
  Admin dashboard: headline platform metrics, the platform activity chart and
  a top-models rollup. All numbers come from `Magus.Usage.AdminStats` SQL
  aggregates and load via `assign_async`, so the page shell renders instantly.
  """
  use MagusWeb, :live_view

  alias Magus.Usage.AdminStats
  alias MagusWeb.Formatters
  alias MagusWeb.Layouts
  alias Phoenix.LiveView.AsyncResult

  @top_models_days 30
  @top_models_limit 10

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Admin Dashboard")
      |> assign(:current_path, "/admin")
      |> assign(:top_models_days, @top_models_days)
      |> load_metrics()

    {:ok, socket}
  end

  # Static render (SEO/first paint) shows the loading state; the connected
  # mount kicks off the real queries so they only run once.
  defp load_metrics(socket) do
    if connected?(socket) do
      socket
      |> assign_async(:metrics, fn -> {:ok, %{metrics: AdminStats.overview()}} end)
      |> assign_async(:top_models, fn ->
        since = DateTime.add(DateTime.utc_now(), -@top_models_days, :day)

        {:ok,
         %{top_models: AdminStats.model_totals(since: since) |> Enum.take(@top_models_limit)}}
      end)
    else
      socket
      |> assign(:metrics, AsyncResult.loading())
      |> assign(:top_models, AsyncResult.loading())
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_metrics(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Dashboard</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Overview of your platform's activity and usage
            </p>
          </div>
          <button
            type="button"
            phx-click="refresh"
            disabled={!!@metrics.loading}
            class="btn btn-outline btn-sm"
          >
            <.icon
              name="lucide-refresh-cw"
              class={["w-4 h-4", @metrics.loading && "animate-spin"]}
            /> Refresh
          </button>
        </div>

        <%!-- Metrics Cards --%>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4" data-test-metric-cards>
          <.async_result :let={metrics} assign={@metrics}>
            <:loading>
              <.metric_skeleton :for={_i <- 1..4} />
            </:loading>
            <:failed>
              <div class="col-span-full alert alert-error">Failed to load metrics.</div>
            </:failed>
            <.metric_card
              title="Active Users"
              value={metrics.active_users}
              subtitle="Last 15 minutes"
              icon="lucide-users"
              color={:primary}
            />
            <.metric_card
              title="Total Users"
              value={Formatters.format_number(metrics.total_users)}
              subtitle="Registered users"
              icon="lucide-users"
              color={:secondary}
            />
            <.metric_card
              title="Total Messages"
              value={Formatters.format_number(metrics.total_messages)}
              subtitle="All time"
              icon="lucide-messages-square"
              color={:accent}
            />
            <.metric_card
              title="Total Cost"
              value={Formatters.format_cost(metrics.total_cost)}
              subtitle="All usage"
              icon="lucide-dollar-sign"
              color={:warning}
            />
          </.async_result>
        </div>

        <%!-- Activity Chart --%>
        <.live_component
          module={MagusWeb.Admin.Components.ActivityChartComponent}
          id="platform-activity"
          title="Platform Message Activity"
        />

        <%!-- Top Models --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="card-title text-base-content">Top Models</h2>
                <p class="text-sm text-base-content/60">
                  By cost, last {@top_models_days} days
                </p>
              </div>
              <.link navigate={~p"/admin/usage"} class="btn btn-ghost btn-xs">
                Usage analytics <.icon name="lucide-arrow-right" class="w-3 h-3" />
              </.link>
            </div>
            <div class="mt-2 overflow-x-auto">
              <.async_result :let={top_models} assign={@top_models}>
                <:loading>
                  <div class="flex items-center justify-center py-8">
                    <span class="loading loading-spinner"></span>
                  </div>
                </:loading>
                <:failed>
                  <p class="text-center text-error py-8">Failed to load model usage.</p>
                </:failed>
                <p :if={top_models == []} class="text-center text-base-content/50 py-8">
                  No usage data available
                </p>
                <table :if={top_models != []} class="table table-sm" data-test-top-models>
                  <thead>
                    <tr class="bg-base-300/50">
                      <th>Model</th>
                      <th class="text-right">Requests</th>
                      <th class="text-right">Cost</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- top_models} class="hover:bg-base-300/30" data-test-top-model>
                      <td class="font-medium text-sm">{row.model || "Unknown"}</td>
                      <td class="text-right font-mono text-sm">
                        {Formatters.format_number(row.count)}
                      </td>
                      <td class="text-right font-mono text-sm">
                        {Formatters.format_cost(row.cost)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.async_result>
            </div>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :subtitle, :string, required: true
  attr :icon, :string, required: true
  attr :color, :atom, default: :primary, values: [:primary, :secondary, :accent, :warning]

  defp metric_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300" data-test-metric-card>
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div>
            <p class="text-sm font-medium text-base-content/60">{@title}</p>
            <p class="text-2xl font-bold text-base-content mt-1">{@value}</p>
            <p class="text-xs text-base-content/50 mt-1">{@subtitle}</p>
          </div>
          <div class={["p-2 rounded-lg", icon_bg(@color)]}>
            <.icon name={@icon} class={["w-6 h-6", icon_text(@color)]} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp metric_skeleton(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 animate-pulse">
      <div class="card-body p-4 space-y-2">
        <div class="h-4 w-24 bg-base-300 rounded"></div>
        <div class="h-8 w-16 bg-base-300 rounded"></div>
        <div class="h-3 w-20 bg-base-300 rounded"></div>
      </div>
    </div>
    """
  end

  # Full literal class names so Tailwind's scanner picks them up — string
  # interpolation like "bg-#{color}/10" never makes it into the build.
  defp icon_bg(:primary), do: "bg-primary/10"
  defp icon_bg(:secondary), do: "bg-secondary/10"
  defp icon_bg(:accent), do: "bg-accent/10"
  defp icon_bg(:warning), do: "bg-warning/10"

  defp icon_text(:primary), do: "text-primary"
  defp icon_text(:secondary), do: "text-secondary"
  defp icon_text(:accent), do: "text-accent"
  defp icon_text(:warning), do: "text-warning"
end
