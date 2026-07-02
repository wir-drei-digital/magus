defmodule MagusWeb.Admin.UsageLive do
  @moduledoc """
  Admin usage analytics page with Chart.js visualizations.

  Filters (time range, model) live in the URL query string; all chart data is
  computed by `Magus.Usage.AdminStats` SQL rollups and loaded via
  `assign_async` — no raw usage rows are ever held in the LiveView.

  Charts:
  1. Billable vs Non-billable (stacked bar)
  2. Usage by Action (stacked bar)
  3. Messages vs Cost by Model (scatter)
  4. Cost by Action (doughnut)
  5. Token Distribution (histogram)
  6. Finish Reason Breakdown (doughnut)
  7. Top Users Table (sortable)
  """
  use MagusWeb, :live_view

  alias Magus.Usage.AdminStats
  alias MagusWeb.Admin.Charts
  alias MagusWeb.Formatters
  alias MagusWeb.Layouts
  alias Phoenix.LiveView.AsyncResult

  @time_ranges [
    {"24h", "Last 24 hours"},
    {"48h", "Last 48 hours"},
    {"3d", "Last 3 days"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"},
    {"90d", "Last 90 days"},
    {"all", "All time"}
  ]
  @range_keys Enum.map(@time_ranges, &elem(&1, 0))

  # The stacked time-series charts need a bounded axis even for "all time";
  # totals/doughnuts stay unbounded.
  @all_time_series_days 365

  @user_sort_fields ~w(email requests billable cost tokens)
  @top_users_shown 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Usage Analytics")
      |> assign(:current_path, "/admin/usage")
      |> assign(:time_ranges, @time_ranges)
      |> assign(:top_users_shown, @top_users_shown)
      |> assign(:users_sort, "cost")
      |> assign(:users_dir, :desc)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = normalize(params["range"], @range_keys, "24h")
    model = presence(params["model"])

    socket =
      socket
      |> assign(:range, range)
      |> assign(:model, model)
      |> load_analytics()

    {:noreply, socket}
  end

  defp load_analytics(socket) do
    %{range: range, model: model} = socket.assigns

    if connected?(socket) do
      assign_async(socket, :analytics, fn ->
        {:ok, %{analytics: compute_analytics(range, model)}}
      end)
    else
      assign(socket, :analytics, AsyncResult.loading())
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    range = normalize(params["time_range"], @range_keys, socket.assigns.range)
    model = presence(params["model"])

    query =
      Enum.reject([{"range", range}, {"model", model}], fn
        {"range", "24h"} -> true
        {_k, v} -> v in [nil, ""]
      end)

    {:noreply, push_patch(socket, to: ~p"/admin/usage?#{query}")}
  end

  @impl true
  def handle_event("sort_users", %{"by" => field}, socket) when field in @user_sort_fields do
    {sort, dir} =
      if socket.assigns.users_sort == field do
        {field, if(socket.assigns.users_dir == :asc, do: :desc, else: :asc)}
      else
        {field, :desc}
      end

    {:noreply, socket |> assign(:users_sort, sort) |> assign(:users_dir, dir)}
  end

  def handle_event("sort_users", _params, socket), do: {:noreply, socket}

  # ── Analytics assembly (runs inside assign_async) ──────────────────────────

  defp compute_analytics(range, model) do
    filters = [since: range_start(range), model: model]

    series_since =
      range_start(range) || DateTime.add(DateTime.utc_now(), -@all_time_series_days, :day)

    series_filters = Keyword.put(filters, :since, series_since)
    bucket_seconds = bucket_seconds(range)
    label = label_fn(range)

    series_opts = [since: series_since, bucket_seconds: bucket_seconds, label: label]

    %{
      summary: AdminStats.summary(filters),
      billable_chart:
        AdminStats.bucketed_counts(:billable, bucket_seconds, series_filters)
        |> Charts.stacked_time_series(
          series_opts ++
            [
              series: [true, false],
              series_label: &billable_label/1,
              series_color: &billable_color/2
            ]
        ),
      action_chart:
        AdminStats.bucketed_counts(:action, bucket_seconds, series_filters)
        |> Charts.stacked_time_series(series_opts),
      model_scatter_chart: scatter_chart(AdminStats.model_totals(filters)),
      cost_by_action_chart: cost_by_action_chart(AdminStats.action_totals(filters)),
      token_histogram: token_histogram_chart(AdminStats.token_histogram(filters)),
      finish_reason_chart: finish_reason_chart(AdminStats.finish_reasons(filters)),
      top_users: AdminStats.user_totals(filters),
      # All-time model list so the dropdown is stable across windows.
      models: AdminStats.model_names()
    }
  end

  defp range_start("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  defp range_start("48h"), do: DateTime.add(DateTime.utc_now(), -2, :day)
  defp range_start("3d"), do: DateTime.add(DateTime.utc_now(), -3, :day)
  defp range_start("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp range_start("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp range_start("90d"), do: DateTime.add(DateTime.utc_now(), -90, :day)
  defp range_start("all"), do: nil

  defp bucket_seconds(range) when range in ["24h", "48h", "3d"], do: 3_600
  defp bucket_seconds(_range), do: 86_400

  defp label_fn("24h"), do: &Charts.hour_label/1
  defp label_fn(range) when range in ["48h", "3d"], do: &Charts.day_hour_label/1
  defp label_fn(_range), do: &Charts.month_day_label/1

  defp billable_label(true), do: "Billable"
  defp billable_label(false), do: "Non-billable"

  defp billable_color(true, _idx), do: "rgba(59, 130, 246, 0.8)"
  defp billable_color(false, _idx), do: "rgba(156, 163, 175, 0.8)"

  defp scatter_chart(model_totals) do
    datasets =
      model_totals
      |> Enum.with_index()
      |> Enum.map(fn {row, idx} ->
        %{
          label: row.model || "Unknown",
          data: [%{x: row.cost |> Decimal.round(4) |> Decimal.to_float(), y: row.count}],
          backgroundColor: Charts.color_at(idx),
          pointRadius: 8,
          pointHoverRadius: 10
        }
      end)

    %{datasets: datasets}
  end

  defp cost_by_action_chart(action_totals) do
    top = Enum.take(action_totals, 10)

    Charts.doughnut(
      Enum.map(top, &(&1.action || "Unknown")),
      Enum.map(top, &(&1.cost |> Decimal.round(4) |> Decimal.to_float()))
    )
  end

  defp token_histogram_chart(histogram) do
    %{
      labels: histogram.labels,
      datasets: [%{data: histogram.counts, backgroundColor: "rgba(59, 130, 246, 0.8)"}],
      median: histogram.median
    }
  end

  defp finish_reason_chart(finish_reasons) do
    Charts.doughnut(
      Enum.map(finish_reasons, &(&1.reason || "Unknown")),
      Enum.map(finish_reasons, & &1.count)
    )
  end

  defp sorted_users(users, sort, dir) do
    sorted =
      case sort do
        "email" -> Enum.sort_by(users, &(&1.email || ""), dir)
        "requests" -> Enum.sort_by(users, & &1.total_requests, dir)
        "billable" -> Enum.sort_by(users, & &1.billable_requests, dir)
        "tokens" -> Enum.sort_by(users, & &1.total_tokens, dir)
        _cost -> Enum.sort_by(users, & &1.total_cost, {dir, Decimal})
      end

    Enum.take(sorted, @top_users_shown)
  end

  defp normalize(value, allowed, default) do
    if is_binary(value) and value in allowed, do: value, else: default
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Usage Analytics</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Detailed usage statistics and visualizations
            </p>
          </div>

          <%!-- Filters --%>
          <form phx-change="filter" class="flex flex-wrap gap-2">
            <select class="select select-bordered select-sm" name="time_range">
              <option :for={{value, label} <- @time_ranges} value={value} selected={@range == value}>
                {label}
              </option>
            </select>

            <select class="select select-bordered select-sm" name="model">
              <option value="">All Models</option>
              <option
                :for={model <- (@analytics.ok? && @analytics.result.models) || List.wrap(@model)}
                value={model}
                selected={@model == model}
              >
                {model}
              </option>
            </select>
          </form>
        </div>

        <.async_result :let={analytics} assign={@analytics}>
          <:loading>
            <div class="flex items-center justify-center py-16">
              <span class="loading loading-spinner loading-lg"></span>
            </div>
          </:loading>
          <:failed>
            <div class="alert alert-error">Failed to load usage analytics.</div>
          </:failed>

          <%!-- Summary Cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4" data-test-usage-summary>
            <.stat_card
              title="Total Requests"
              value={Formatters.format_number(analytics.summary.total_requests)}
              icon="lucide-activity"
            />
            <.stat_card
              title="Billable Requests"
              value={Formatters.format_number(analytics.summary.billable_count)}
              icon="lucide-receipt"
            />
            <.stat_card
              title="Total Cost"
              value={Formatters.format_cost(analytics.summary.total_cost)}
              icon="lucide-dollar-sign"
            />
            <.stat_card
              title="Total Tokens"
              value={Formatters.format_number(analytics.summary.total_tokens)}
              icon="lucide-hash"
            />
          </div>

          <%!-- Charts Row 1: Billable and Action --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <.chart_card title="Billable vs Non-billable" subtitle="Request distribution over time">
              <canvas
                id="billable-chart"
                phx-hook="StackedBarChart"
                data-chart-data={Jason.encode!(analytics.billable_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Usage by Action" subtitle="Requests grouped by action type">
              <canvas
                id="action-chart"
                phx-hook="StackedBarChart"
                data-chart-data={Jason.encode!(analytics.action_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>
          </div>

          <%!-- Charts Row 2: Cost Charts --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <.chart_card title="Messages vs Cost by Model" subtitle="Each point is a model">
              <canvas
                id="model-scatter-chart"
                phx-hook="ScatterChart"
                data-chart-data={Jason.encode!(analytics.model_scatter_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Cost by Action" subtitle="Cost distribution by action type">
              <canvas
                id="cost-action-chart"
                phx-hook="DoughnutChart"
                data-chart-data={Jason.encode!(analytics.cost_by_action_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>
          </div>

          <%!-- Charts Row 3: Token Histogram and Finish Reason --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <.chart_card
              title="Token Distribution"
              subtitle={"Median: #{Formatters.format_number(analytics.token_histogram.median)} tokens"}
            >
              <canvas
                id="token-histogram"
                phx-hook="Histogram"
                data-chart-data={Jason.encode!(analytics.token_histogram)}
                data-median={analytics.token_histogram.median}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Finish Reasons" subtitle="Why generations stopped">
              <canvas
                id="finish-reason-chart"
                phx-hook="DoughnutChart"
                data-chart-data={Jason.encode!(analytics.finish_reason_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>
          </div>

          <%!-- Top Users Table --%>
          <.chart_card title="Top Users" subtitle={"Top #{@top_users_shown} by the selected column"}>
            <div class="overflow-x-auto">
              <table class="table table-sm" data-test-top-users>
                <thead>
                  <tr>
                    <.users_header label="Email" field="email" sort={@users_sort} dir={@users_dir} />
                    <.users_header
                      label="Requests"
                      field="requests"
                      sort={@users_sort}
                      dir={@users_dir}
                      align="right"
                    />
                    <.users_header
                      label="Billable"
                      field="billable"
                      sort={@users_sort}
                      dir={@users_dir}
                      align="right"
                    />
                    <.users_header
                      label="Cost"
                      field="cost"
                      sort={@users_sort}
                      dir={@users_dir}
                      align="right"
                    />
                    <.users_header
                      label="Tokens"
                      field="tokens"
                      sort={@users_sort}
                      dir={@users_dir}
                      align="right"
                    />
                  </tr>
                </thead>
                <tbody>
                  <tr :for={user <- sorted_users(analytics.top_users, @users_sort, @users_dir)}>
                    <td class="text-base-content/80">{user.email || "Unknown"}</td>
                    <td class="text-right">{Formatters.format_number(user.total_requests)}</td>
                    <td class="text-right">{Formatters.format_number(user.billable_requests)}</td>
                    <td class="text-right font-mono">{Formatters.format_cost(user.total_cost)}</td>
                    <td class="text-right">{Formatters.format_number(user.total_tokens)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.chart_card>
        </.async_result>
      </div>
    </Layouts.admin>
    """
  end

  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :sort, :string, required: true
  attr :dir, :atom, required: true
  attr :align, :string, default: "left"

  defp users_header(assigns) do
    ~H"""
    <th
      class={["cursor-pointer hover:bg-base-300", @align == "right" && "text-right"]}
      phx-click="sort_users"
      phx-value-by={@field}
    >
      {@label}
      <span :if={@sort == @field}>{if @dir == :asc, do: "↑", else: "↓"}</span>
    </th>
    """
  end

  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-start justify-between">
          <div>
            <p class="text-sm font-medium text-base-content/60">{@title}</p>
            <p class="text-2xl font-bold text-base-content mt-1">{@value}</p>
          </div>
          <div class="p-2 rounded-lg bg-primary/10">
            <.icon name={@icon} class="w-5 h-5 text-primary" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :inner_block, required: true

  defp chart_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body">
        <h2 class="card-title text-base-content">{@title}</h2>
        <p :if={@subtitle} class="text-sm text-base-content/60">{@subtitle}</p>
        <div class="mt-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end
end
