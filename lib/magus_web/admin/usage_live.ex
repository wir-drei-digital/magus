defmodule MagusWeb.Admin.UsageLive do
  @moduledoc """
  Admin usage analytics page with Chart.js visualizations.

  Features:
  - Time range and model filters
  - Summary stat cards (total requests, billable count, total cost, total tokens)
  - Charts:
    1. Billable vs Non-billable (stacked bar)
    2. Usage by Action (stacked bar)
    3. Cost by Model (doughnut)
    4. Cost by Action (doughnut)
    5. Token Distribution (histogram)
    6. Finish Reason Breakdown (doughnut)
    7. Top Users Table (sortable)
    8. Peak Hours Heatmap
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  require Ash.Query

  @time_ranges [
    {"24h", "Last 24 hours"},
    {"48h", "Last 48 hours"},
    {"3d", "Last 3 days"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"},
    {"90d", "Last 90 days"},
    {"all", "All time"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Usage Analytics")
      |> assign(:current_path, "/admin/usage")
      |> assign(:loading, true)
      |> assign(:time_range, "24h")
      |> assign(:selected_model, nil)
      |> assign(:models, [])
      |> assign(:time_ranges, @time_ranges)
      |> assign(:sort_by, "cost")
      |> assign(:sort_dir, :desc)

    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    models = get_available_models()
    socket = socket |> assign(:models, models) |> load_analytics()
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    time_range = Map.get(params, "time_range", socket.assigns.time_range)
    model = Map.get(params, "model", "")
    selected_model = if model == "", do: nil, else: model

    socket =
      socket
      |> assign(:time_range, time_range)
      |> assign(:selected_model, selected_model)
      |> assign(:loading, true)

    send(self(), :load_data)
    {:noreply, socket}
  end

  @impl true
  def handle_event("sort_users", %{"by" => field}, socket) do
    {sort_by, sort_dir} =
      if socket.assigns.sort_by == field do
        {field, if(socket.assigns.sort_dir == :asc, do: :desc, else: :asc)}
      else
        {field, :desc}
      end

    top_users = sort_users(socket.assigns.top_users_raw, sort_by, sort_dir)

    {:noreply,
     socket
     |> assign(:sort_by, sort_by)
     |> assign(:sort_dir, sort_dir)
     |> assign(:top_users, top_users)}
  end

  defp load_analytics(socket) do
    time_range = socket.assigns.time_range
    selected_model = socket.assigns.selected_model

    usages = fetch_usages(time_range, selected_model)

    summary = calculate_summary(usages)
    billable_chart = build_billable_chart(usages, time_range)
    action_chart = build_action_chart(usages, time_range)
    model_scatter_chart = build_model_scatter_chart(usages)
    cost_by_action_chart = build_cost_by_action_chart(usages)
    token_histogram = build_token_histogram(usages)
    finish_reason_chart = build_finish_reason_chart(usages)
    top_users_raw = build_top_users(usages)
    top_users = sort_users(top_users_raw, socket.assigns.sort_by, socket.assigns.sort_dir)
    peak_hours = build_peak_hours_heatmap(usages)

    socket
    |> assign(:loading, false)
    |> assign(:summary, summary)
    |> assign(:billable_chart, billable_chart)
    |> assign(:action_chart, action_chart)
    |> assign(:model_scatter_chart, model_scatter_chart)
    |> assign(:cost_by_action_chart, cost_by_action_chart)
    |> assign(:token_histogram, token_histogram)
    |> assign(:finish_reason_chart, finish_reason_chart)
    |> assign(:top_users_raw, top_users_raw)
    |> assign(:top_users, top_users)
    |> assign(:peak_hours, peak_hours)
  end

  defp fetch_usages(time_range, selected_model) do
    since = time_range_to_datetime(time_range)

    query =
      Magus.Usage.MessageUsage
      |> Ash.Query.filter(inserted_at >= ^since)

    query =
      if selected_model do
        Ash.Query.filter(query, model_name == ^selected_model)
      else
        query
      end

    Ash.read!(query, authorize?: false, load: [:user])
  end

  defp get_available_models do
    Magus.Usage.MessageUsage
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.model_name)
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp time_range_to_datetime("24h"), do: DateTime.add(DateTime.utc_now(), -1, :day)
  defp time_range_to_datetime("48h"), do: DateTime.add(DateTime.utc_now(), -2, :day)
  defp time_range_to_datetime("3d"), do: DateTime.add(DateTime.utc_now(), -3, :day)
  defp time_range_to_datetime("7d"), do: DateTime.add(DateTime.utc_now(), -7, :day)
  defp time_range_to_datetime("30d"), do: DateTime.add(DateTime.utc_now(), -30, :day)
  defp time_range_to_datetime("90d"), do: DateTime.add(DateTime.utc_now(), -90, :day)
  defp time_range_to_datetime("all"), do: ~U[2020-01-01 00:00:00Z]
  defp time_range_to_datetime(_), do: DateTime.add(DateTime.utc_now(), -30, :day)

  # Summary calculations
  defp calculate_summary(usages) do
    total_requests = length(usages)
    billable_count = Enum.count(usages, & &1.billable)

    total_cost =
      Enum.reduce(usages, Decimal.new(0), fn u, acc ->
        Decimal.add(acc, u.total_cost || Decimal.new(0))
      end)

    total_tokens = Enum.reduce(usages, 0, fn u, acc -> acc + (u.total_tokens || 0) end)

    %{
      total_requests: total_requests,
      billable_count: billable_count,
      total_cost: total_cost,
      total_tokens: total_tokens
    }
  end

  # Chart builders
  defp build_billable_chart(usages, time_range) do
    grouped = group_by_date(usages, time_range)
    labels = generate_all_time_slots(time_range)

    billable_data =
      Enum.map(labels, fn date ->
        grouped |> Map.get(date, []) |> Enum.count(& &1.billable)
      end)

    non_billable_data =
      Enum.map(labels, fn date ->
        grouped |> Map.get(date, []) |> Enum.count(&(!&1.billable))
      end)

    %{
      labels: labels,
      datasets: [
        %{label: "Billable", data: billable_data, backgroundColor: "rgba(59, 130, 246, 0.8)"},
        %{
          label: "Non-billable",
          data: non_billable_data,
          backgroundColor: "rgba(156, 163, 175, 0.8)"
        }
      ]
    }
  end

  defp build_action_chart(usages, time_range) do
    grouped = group_by_date(usages, time_range)
    labels = generate_all_time_slots(time_range)

    # Get all unique action names
    actions =
      usages
      |> Enum.map(& &1.action_name)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    colors = [
      "rgba(59, 130, 246, 0.8)",
      "rgba(16, 185, 129, 0.8)",
      "rgba(245, 158, 11, 0.8)",
      "rgba(239, 68, 68, 0.8)",
      "rgba(139, 92, 246, 0.8)",
      "rgba(236, 72, 153, 0.8)",
      "rgba(20, 184, 166, 0.8)",
      "rgba(251, 146, 60, 0.8)"
    ]

    datasets =
      actions
      |> Enum.with_index()
      |> Enum.map(fn {action, idx} ->
        data =
          Enum.map(labels, fn date ->
            grouped
            |> Map.get(date, [])
            |> Enum.count(&(&1.action_name == action))
          end)

        %{
          label: action || "Unknown",
          data: data,
          backgroundColor: Enum.at(colors, rem(idx, length(colors)))
        }
      end)

    %{labels: labels, datasets: datasets}
  end

  defp build_model_scatter_chart(usages) do
    colors = generate_colors(20)

    datasets =
      usages
      |> Enum.group_by(& &1.model_name)
      |> Enum.map(fn {model, records} ->
        cost =
          Enum.reduce(records, Decimal.new(0), fn r, acc ->
            Decimal.add(acc, r.total_cost || Decimal.new(0))
          end)

        {model || "Unknown", length(records), cost |> Decimal.round(4) |> Decimal.to_float()}
      end)
      |> Enum.sort_by(fn {_, _, cost} -> cost end, :desc)
      |> Enum.with_index()
      |> Enum.map(fn {{model, count, cost}, idx} ->
        %{
          label: model,
          data: [%{x: cost, y: count}],
          backgroundColor: Enum.at(colors, rem(idx, length(colors))),
          pointRadius: 8,
          pointHoverRadius: 10
        }
      end)

    %{datasets: datasets}
  end

  defp build_cost_by_action_chart(usages) do
    by_action =
      usages
      |> Enum.group_by(& &1.action_name)
      |> Enum.map(fn {action, records} ->
        cost =
          Enum.reduce(records, Decimal.new(0), fn r, acc ->
            Decimal.add(acc, r.total_cost || Decimal.new(0))
          end)

        {action || "Unknown", cost}
      end)
      |> Enum.sort_by(fn {_, cost} -> cost end, {:desc, Decimal})
      |> Enum.take(10)

    labels = Enum.map(by_action, fn {action, _} -> action end)

    data =
      Enum.map(by_action, fn {_, cost} ->
        cost |> Decimal.round(4) |> Decimal.to_float()
      end)

    colors = generate_colors(length(labels))

    %{
      labels: labels,
      datasets: [%{data: data, backgroundColor: colors}]
    }
  end

  defp build_token_histogram(usages) do
    tokens = usages |> Enum.map(& &1.total_tokens) |> Enum.reject(&is_nil/1)

    if tokens == [] do
      %{
        labels: [],
        datasets: [%{data: [], backgroundColor: "rgba(59, 130, 246, 0.8)"}],
        median: 0
      }
    else
      # Logarithmic bins: 0-100, 100-1000, 1000-10000, 10000-100000, 100000+
      bins = [
        {0, 100, "0-100"},
        {100, 1000, "100-1K"},
        {1000, 10000, "1K-10K"},
        {10000, 100_000, "10K-100K"},
        {100_000, 1_000_000, "100K-1M"},
        {1_000_000, :infinity, "1M+"}
      ]

      counts =
        Enum.map(bins, fn {min, max, _label} ->
          Enum.count(tokens, fn t ->
            t >= min && (max == :infinity || t < max)
          end)
        end)

      labels = Enum.map(bins, fn {_, _, label} -> label end)
      median = Enum.sort(tokens) |> Enum.at(div(length(tokens), 2)) || 0

      %{
        labels: labels,
        datasets: [%{data: counts, backgroundColor: "rgba(59, 130, 246, 0.8)"}],
        median: median
      }
    end
  end

  defp build_finish_reason_chart(usages) do
    by_reason =
      usages
      |> Enum.group_by(& &1.finish_reason)
      |> Enum.map(fn {reason, records} -> {reason || "Unknown", length(records)} end)
      |> Enum.sort_by(fn {_, count} -> count end, :desc)

    labels = Enum.map(by_reason, fn {reason, _} -> reason end)
    data = Enum.map(by_reason, fn {_, count} -> count end)
    colors = generate_colors(length(labels))

    %{
      labels: labels,
      datasets: [%{data: data, backgroundColor: colors}]
    }
  end

  defp build_top_users(usages) do
    usages
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {user_id, records} ->
      user = List.first(records).user

      total_cost =
        Enum.reduce(records, Decimal.new(0), fn r, acc ->
          Decimal.add(acc, r.total_cost || Decimal.new(0))
        end)

      %{
        user_id: user_id,
        email: user && user.email,
        total_requests: length(records),
        billable_requests: Enum.count(records, & &1.billable),
        total_cost: total_cost,
        total_tokens: Enum.reduce(records, 0, fn r, acc -> acc + (r.total_tokens || 0) end)
      }
    end)
  end

  defp sort_users(users, sort_by, sort_dir) do
    sorter =
      case sort_by do
        "email" -> & &1.email
        "requests" -> & &1.total_requests
        "billable" -> & &1.billable_requests
        "cost" -> & &1.total_cost
        "tokens" -> & &1.total_tokens
        _ -> & &1.total_cost
      end

    sorted =
      if sort_by == "cost" do
        Enum.sort_by(users, sorter, {sort_dir, Decimal})
      else
        Enum.sort_by(users, sorter, sort_dir)
      end

    Enum.take(sorted, 20)
  end

  defp build_peak_hours_heatmap(usages) do
    # Build a 7x24 grid (days x hours)
    # Days: 0=Monday, 6=Sunday
    # Hours: 0-23

    counts =
      usages
      |> Enum.reduce(%{}, fn usage, acc ->
        day = Date.day_of_week(DateTime.to_date(usage.inserted_at)) - 1
        hour = usage.inserted_at.hour
        key = {day, hour}
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    max_count = counts |> Map.values() |> Enum.max(fn -> 1 end)

    # Build grid data
    for day <- 0..6, hour <- 0..23 do
      count = Map.get(counts, {day, hour}, 0)
      intensity = if max_count > 0, do: count / max_count, else: 0

      %{
        day: day,
        hour: hour,
        count: count,
        intensity: intensity
      }
    end
  end

  # Helpers
  defp generate_all_time_slots(time_range) when time_range in ["24h", "48h", "3d"] do
    hours =
      case time_range do
        "24h" -> 24
        "48h" -> 48
        "3d" -> 72
      end

    now = DateTime.utc_now()

    0..(hours - 1)
    |> Enum.map(fn hours_ago ->
      now
      |> DateTime.add(-hours_ago, :hour)
      |> format_hour_slot(time_range)
    end)
    |> Enum.reverse()
  end

  defp generate_all_time_slots(time_range) do
    days =
      case time_range do
        "7d" -> 7
        "30d" -> 30
        "90d" -> 90
        "all" -> 365
        _ -> 30
      end

    today = Date.utc_today()

    0..(days - 1)
    |> Enum.map(fn days_ago ->
      today |> Date.add(-days_ago) |> format_date_slot()
    end)
    |> Enum.reverse()
  end

  defp group_by_date(usages, time_range) when time_range in ["24h", "48h", "3d"] do
    Enum.group_by(usages, fn usage ->
      format_hour_slot(usage.inserted_at, time_range)
    end)
  end

  defp group_by_date(usages, _time_range) do
    Enum.group_by(usages, fn usage ->
      usage.inserted_at |> DateTime.to_date() |> format_date_slot()
    end)
  end

  defp format_hour_slot(datetime, "24h") do
    hour = datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hour}:00"
  end

  defp format_hour_slot(datetime, _time_range) do
    day_abbr = day_abbr(Date.day_of_week(DateTime.to_date(datetime)))
    hour = datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{day_abbr} #{hour}:00"
  end

  defp format_date_slot(date) do
    month_abbr = month_abbr(date.month)
    "#{month_abbr} #{date.day}"
  end

  defp day_abbr(1), do: "Mon"
  defp day_abbr(2), do: "Tue"
  defp day_abbr(3), do: "Wed"
  defp day_abbr(4), do: "Thu"
  defp day_abbr(5), do: "Fri"
  defp day_abbr(6), do: "Sat"
  defp day_abbr(7), do: "Sun"

  defp month_abbr(1), do: "Jan"
  defp month_abbr(2), do: "Feb"
  defp month_abbr(3), do: "Mar"
  defp month_abbr(4), do: "Apr"
  defp month_abbr(5), do: "May"
  defp month_abbr(6), do: "Jun"
  defp month_abbr(7), do: "Jul"
  defp month_abbr(8), do: "Aug"
  defp month_abbr(9), do: "Sep"
  defp month_abbr(10), do: "Oct"
  defp month_abbr(11), do: "Nov"
  defp month_abbr(12), do: "Dec"

  defp generate_colors(count) do
    base_colors = [
      "rgba(59, 130, 246, 0.8)",
      "rgba(16, 185, 129, 0.8)",
      "rgba(245, 158, 11, 0.8)",
      "rgba(239, 68, 68, 0.8)",
      "rgba(139, 92, 246, 0.8)",
      "rgba(236, 72, 153, 0.8)",
      "rgba(20, 184, 166, 0.8)",
      "rgba(251, 146, 60, 0.8)",
      "rgba(34, 197, 94, 0.8)",
      "rgba(168, 85, 247, 0.8)"
    ]

    Enum.take(Stream.cycle(base_colors), count)
  end

  defp day_name(0), do: "Mon"
  defp day_name(1), do: "Tue"
  defp day_name(2), do: "Wed"
  defp day_name(3), do: "Thu"
  defp day_name(4), do: "Fri"
  defp day_name(5), do: "Sat"
  defp day_name(6), do: "Sun"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num), do: to_string(num)

  defp format_cost(nil), do: "$0.00"

  defp format_cost(decimal) do
    "$" <> (decimal |> Decimal.round(4) |> Decimal.to_string())
  end

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
              <%= for {value, label} <- @time_ranges do %>
                <option value={value} selected={@time_range == value}>{label}</option>
              <% end %>
            </select>

            <select class="select select-bordered select-sm" name="model">
              <option value="">All Models</option>
              <%= for model <- @models do %>
                <option value={model} selected={@selected_model == model}>{model}</option>
              <% end %>
            </select>
          </form>
        </div>

        <%= if @loading do %>
          <div class="flex items-center justify-center py-16">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        <% else %>
          <%!-- Summary Cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
            <.stat_card
              title="Total Requests"
              value={format_number(@summary.total_requests)}
              icon="lucide-activity"
            />
            <.stat_card
              title="Billable Requests"
              value={format_number(@summary.billable_count)}
              icon="lucide-receipt"
            />
            <.stat_card
              title="Total Cost"
              value={format_cost(@summary.total_cost)}
              icon="lucide-dollar-sign"
            />
            <.stat_card
              title="Total Tokens"
              value={format_number(@summary.total_tokens)}
              icon="lucide-hash"
            />
          </div>

          <%!-- Charts Row 1: Billable and Action --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <.chart_card title="Billable vs Non-billable" subtitle="Request distribution over time">
              <canvas
                id="billable-chart"
                phx-hook="StackedBarChart"
                data-chart-data={Jason.encode!(@billable_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Usage by Action" subtitle="Requests grouped by action type">
              <canvas
                id="action-chart"
                phx-hook="StackedBarChart"
                data-chart-data={Jason.encode!(@action_chart)}
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
                data-chart-data={Jason.encode!(@model_scatter_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Cost by Action" subtitle="Cost distribution by action type">
              <canvas
                id="cost-action-chart"
                phx-hook="DoughnutChart"
                data-chart-data={Jason.encode!(@cost_by_action_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>
          </div>

          <%!-- Charts Row 3: Token Histogram and Finish Reason --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <.chart_card
              title="Token Distribution"
              subtitle={"Median: #{format_number(@token_histogram.median)} tokens"}
            >
              <canvas
                id="token-histogram"
                phx-hook="Histogram"
                data-chart-data={Jason.encode!(@token_histogram)}
                data-median={@token_histogram.median}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>

            <.chart_card title="Finish Reasons" subtitle="Why generations stopped">
              <canvas
                id="finish-reason-chart"
                phx-hook="DoughnutChart"
                data-chart-data={Jason.encode!(@finish_reason_chart)}
                class="w-full h-64"
              >
              </canvas>
            </.chart_card>
          </div>

          <%!-- Top Users Table --%>
          <.chart_card title="Top Users" subtitle="Sorted by usage metrics">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th
                      class="cursor-pointer hover:bg-base-300"
                      phx-click="sort_users"
                      phx-value-by="email"
                    >
                      Email {sort_indicator(@sort_by, @sort_dir, "email")}
                    </th>
                    <th
                      class="text-right cursor-pointer hover:bg-base-300"
                      phx-click="sort_users"
                      phx-value-by="requests"
                    >
                      Requests {sort_indicator(@sort_by, @sort_dir, "requests")}
                    </th>
                    <th
                      class="text-right cursor-pointer hover:bg-base-300"
                      phx-click="sort_users"
                      phx-value-by="billable"
                    >
                      Billable {sort_indicator(@sort_by, @sort_dir, "billable")}
                    </th>
                    <th
                      class="text-right cursor-pointer hover:bg-base-300"
                      phx-click="sort_users"
                      phx-value-by="cost"
                    >
                      Cost {sort_indicator(@sort_by, @sort_dir, "cost")}
                    </th>
                    <th
                      class="text-right cursor-pointer hover:bg-base-300"
                      phx-click="sort_users"
                      phx-value-by="tokens"
                    >
                      Tokens {sort_indicator(@sort_by, @sort_dir, "tokens")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <%= for user <- @top_users do %>
                    <tr>
                      <td class="text-base-content/80">{user.email || "Unknown"}</td>
                      <td class="text-right">{format_number(user.total_requests)}</td>
                      <td class="text-right">{format_number(user.billable_requests)}</td>
                      <td class="text-right font-mono">{format_cost(user.total_cost)}</td>
                      <td class="text-right">{format_number(user.total_tokens)}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </.chart_card>

          <%!-- Peak Hours Heatmap --%>
          <.chart_card title="Peak Hours" subtitle="Request activity by day and hour (UTC)">
            <div class="overflow-x-auto">
              <div class="inline-block">
                <%!-- Hour labels --%>
                <div class="flex mb-1 ml-10">
                  <%= for hour <- 0..23 do %>
                    <div class="w-6 text-xs text-center text-base-content/50">
                      {if rem(hour, 3) == 0, do: hour, else: ""}
                    </div>
                  <% end %>
                </div>
                <%!-- Grid rows --%>
                <%= for day <- 0..6 do %>
                  <div class="flex items-center">
                    <div class="w-10 text-xs text-base-content/60">{day_name(day)}</div>
                    <%= for hour <- 0..23 do %>
                      <% cell = Enum.find(@peak_hours, &(&1.day == day && &1.hour == hour)) %>
                      <div
                        class="w-6 h-6 rounded-sm m-px tooltip"
                        style={"background-color: rgba(59, 130, 246, #{cell && cell.intensity || 0})"}
                        data-tip={"#{day_name(day)} #{hour}:00 - #{cell && cell.count || 0} requests"}
                      >
                      </div>
                    <% end %>
                  </div>
                <% end %>
                <%!-- Legend --%>
                <div class="flex items-center gap-2 mt-3 ml-10">
                  <span class="text-xs text-base-content/50">Less</span>
                  <div class="flex">
                    <div class="w-4 h-4 rounded-sm" style="background-color: rgba(59, 130, 246, 0.1)">
                    </div>
                    <div class="w-4 h-4 rounded-sm" style="background-color: rgba(59, 130, 246, 0.3)">
                    </div>
                    <div class="w-4 h-4 rounded-sm" style="background-color: rgba(59, 130, 246, 0.5)">
                    </div>
                    <div class="w-4 h-4 rounded-sm" style="background-color: rgba(59, 130, 246, 0.7)">
                    </div>
                    <div class="w-4 h-4 rounded-sm" style="background-color: rgba(59, 130, 246, 1.0)">
                    </div>
                  </div>
                  <span class="text-xs text-base-content/50">More</span>
                </div>
              </div>
            </div>
          </.chart_card>
        <% end %>
      </div>
    </Layouts.admin>
    """
  end

  defp sort_indicator(sort_by, sort_dir, field) do
    if sort_by == field do
      if sort_dir == :asc, do: "↑", else: "↓"
    else
      ""
    end
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
