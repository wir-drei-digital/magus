defmodule MagusWeb.Admin.Components.ActivityChartComponent do
  @moduledoc """
  A reusable LiveComponent for displaying message activity charts using Chart.js.

  Shows a stacked bar chart of request counts by action name over time. The
  buckets are computed in SQL (`AdminStats.bucketed_counts/3`) and load via
  `assign_async`, so switching periods never blocks the parent LiveView.

  ## Usage

      # For a specific user:
      <.live_component
        module={MagusWeb.Admin.Components.ActivityChartComponent}
        id="user-activity"
        user_id={@user.id}
        title="User Activity"
      />

      # For all users:
      <.live_component
        module={MagusWeb.Admin.Components.ActivityChartComponent}
        id="all-activity"
        title="Platform Activity"
      />
  """
  use MagusWeb, :live_component

  alias Magus.Usage.AdminStats
  alias MagusWeb.Admin.Charts

  # period -> {window in hours, bucket size in seconds, x-axis label fn}
  @periods %{
    "12h" => {12, 3_600, &Charts.hour_label/1},
    "24h" => {24, 3_600, &Charts.hour_label/1},
    "3d" => {72, 4 * 3_600, &Charts.day_hour_label/1},
    "7d" => {168, 8 * 3_600, &Charts.day_hour_label/1},
    "14d" => {14 * 24, 86_400, &Charts.week_day_label/1},
    "30d" => {30 * 24, 86_400, &Charts.month_day_label/1}
  }

  @period_options ["12h", "24h", "3d", "7d", "14d", "30d"]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :period, "24h")}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:user_id, Map.get(assigns, :user_id))
      |> assign(:title, Map.get(assigns, :title, "Message Activity"))

    # Only reload data if this is the first load; parent re-renders must not
    # refetch (period changes are handled by change_period).
    socket =
      if Map.has_key?(socket.assigns, :chart) do
        socket
      else
        load_chart(socket)
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("change_period", %{"period" => period}, socket)
      when period in @period_options do
    socket =
      socket
      |> assign(:period, period)
      |> load_chart()

    {:noreply, socket}
  end

  def handle_event("change_period", _params, socket), do: {:noreply, socket}

  defp load_chart(socket) do
    %{period: period, user_id: user_id} = socket.assigns
    {hours, bucket_seconds, label_fn} = Map.fetch!(@periods, period)

    assign_async(socket, :chart, fn ->
      since = DateTime.add(DateTime.utc_now(), -hours, :hour)
      rows = AdminStats.bucketed_counts(:action, bucket_seconds, since: since, user_id: user_id)

      {:ok,
       %{
         chart: %{
           data:
             Charts.stacked_time_series(rows,
               since: since,
               bucket_seconds: bucket_seconds,
               label: label_fn
             ),
           total: rows |> Enum.map(& &1.count) |> Enum.sum()
         }
       }}
    end)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :period_options, @period_options)

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="card-title text-base">{@title}</h3>
            <p class="text-xs text-base-content/60">
              Total: {(@chart.ok? && @chart.result.total) || "…"} requests
            </p>
          </div>
          <form phx-change="change_period" phx-target={@myself}>
            <select class="select select-bordered select-xs" name="period">
              <option :for={period <- @period_options} value={period} selected={@period == period}>
                {period_label(period)}
              </option>
            </select>
          </form>
        </div>
        <div class="mt-4 h-48">
          <.async_result :let={chart} assign={@chart}>
            <:loading>
              <div class="flex items-center justify-center h-full">
                <span class="loading loading-spinner"></span>
              </div>
            </:loading>
            <:failed>
              <p class="text-center text-error py-8">Failed to load activity.</p>
            </:failed>
            <canvas
              id={"#{@id}-chart-#{@period}"}
              phx-hook="StackedBarChart"
              data-chart-data={Jason.encode!(chart.data)}
              class="w-full h-48"
            >
            </canvas>
          </.async_result>
        </div>
      </div>
    </div>
    """
  end

  defp period_label("12h"), do: "12 hours"
  defp period_label("24h"), do: "24 hours"
  defp period_label("3d"), do: "3 days"
  defp period_label("7d"), do: "7 days"
  defp period_label("14d"), do: "14 days"
  defp period_label("30d"), do: "30 days"
end
