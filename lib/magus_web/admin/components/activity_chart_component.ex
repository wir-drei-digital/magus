defmodule MagusWeb.Admin.Components.ActivityChartComponent do
  @moduledoc """
  A reusable LiveComponent for displaying message activity charts using Chart.js.

  Shows stacked bar chart by action name over time.
  Uses hourly aggregation for 3d/7d periods, daily for longer periods.

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

  require Ash.Query

  @activity_periods %{
    "12h" => {12, :hour},
    "24h" => {24, :hour},
    "3d" => {3, :day},
    "7d" => {7, :day},
    "14d" => {14, :day},
    "30d" => {30, :day}
  }

  @colors [
    "rgba(59, 130, 246, 0.8)",
    "rgba(16, 185, 129, 0.8)",
    "rgba(245, 158, 11, 0.8)",
    "rgba(239, 68, 68, 0.8)",
    "rgba(139, 92, 246, 0.8)",
    "rgba(236, 72, 153, 0.8)",
    "rgba(20, 184, 166, 0.8)",
    "rgba(251, 146, 60, 0.8)"
  ]

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

    # Only reload data if this is first load or period changed
    socket =
      if not Map.has_key?(socket.assigns, :chart_data) do
        load_chart_data(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("change_period", %{"period" => period}, socket) do
    socket =
      socket
      |> assign(:period, period)
      |> load_chart_data()

    {:noreply, socket}
  end

  defp load_chart_data(socket) do
    %{period: period, user_id: user_id} = socket.assigns

    {amount, unit} = Map.get(@activity_periods, period, {24, :hour})
    since = DateTime.add(DateTime.utc_now(), -amount, unit)

    usages = fetch_usages(user_id, since)
    chart_data = build_chart_data(usages, period)
    total_count = usages |> length()

    socket
    |> assign(:chart_data, chart_data)
    |> assign(:total_count, total_count)
  end

  defp fetch_usages(nil, since) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(inserted_at >= ^since)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_usages(user_id, since) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(user_id == ^user_id and inserted_at >= ^since)
    |> Ash.read!(authorize?: false)
  end

  defp build_chart_data(usages, period) do
    # Determine aggregation: hourly for 3d/7d, daily for longer periods
    use_hourly = period in ["12h", "24h", "3d", "7d"]

    now = DateTime.utc_now()

    # Get all unique action names
    actions =
      usages
      |> Enum.map(& &1.action_name)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    actions = if actions == [], do: ["Unknown"], else: actions

    # Generate time slots with start/end times for proper bucketing
    {slot_ranges, labels} = generate_time_slots(period, now, use_hourly)

    # Build datasets for each action
    datasets =
      actions
      |> Enum.with_index()
      |> Enum.map(fn {action, idx} ->
        data =
          Enum.map(slot_ranges, fn {slot_start, slot_end} ->
            usages
            |> Enum.count(fn usage ->
              usage.action_name == action &&
                DateTime.compare(usage.inserted_at, slot_start) != :lt &&
                DateTime.compare(usage.inserted_at, slot_end) == :lt
            end)
          end)

        %{
          label: action || "Unknown",
          data: data,
          backgroundColor: Enum.at(@colors, rem(idx, length(@colors)))
        }
      end)

    %{labels: labels, datasets: datasets}
  end

  defp generate_time_slots(period, now, true = _use_hourly) do
    hours =
      case period do
        "12h" -> 12
        "24h" -> 24
        "3d" -> 72
        "7d" -> 168
        _ -> 24
      end

    # Bucket size: 1h for 12h/24h, 4h for 3d, 8h for 7d
    bucket_hours =
      case period do
        "12h" -> 1
        "24h" -> 1
        "3d" -> 4
        "7d" -> 8
        _ -> 1
      end

    num_buckets = div(hours, bucket_hours)

    slot_ranges =
      Enum.map(0..(num_buckets - 1), fn bucket_idx ->
        # Calculate start of this bucket (going backwards from now)
        bucket_start_hours_ago = hours - bucket_idx * bucket_hours
        bucket_end_hours_ago = hours - (bucket_idx + 1) * bucket_hours

        slot_start = DateTime.add(now, -bucket_start_hours_ago, :hour)
        slot_end = DateTime.add(now, -bucket_end_hours_ago, :hour)
        {slot_start, slot_end}
      end)

    labels =
      Enum.map(slot_ranges, fn {slot_start, _} ->
        if period in ["3d", "7d"] do
          Calendar.strftime(slot_start, "%a %H:00")
        else
          Calendar.strftime(slot_start, "%H:00")
        end
      end)

    {slot_ranges, labels}
  end

  defp generate_time_slots(period, now, false = _use_hourly) do
    days =
      case period do
        "14d" -> 14
        "30d" -> 30
        _ -> 7
      end

    slot_ranges =
      Enum.map(0..(days - 1), fn day_idx ->
        # Start of day (going backwards from now)
        day_start = now |> DateTime.add(-(days - 1 - day_idx), :day) |> start_of_day()
        day_end = DateTime.add(day_start, 1, :day)
        {day_start, day_end}
      end)

    labels =
      Enum.map(slot_ranges, fn {slot_start, _} ->
        if days <= 14 do
          Calendar.strftime(slot_start, "%a %d")
        else
          Calendar.strftime(slot_start, "%d")
        end
      end)

    {slot_ranges, labels}
  end

  defp start_of_day(datetime) do
    %{datetime | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body">
        <div class="flex items-center justify-between">
          <div>
            <h3 class="card-title text-base">{@title}</h3>
            <p class="text-xs text-base-content/60">
              Total: {@total_count} requests
            </p>
          </div>
          <form phx-change="change_period" phx-target={@myself}>
            <select class="select select-bordered select-xs" name="period">
              <option value="12h" selected={@period == "12h"}>12 hours</option>
              <option value="24h" selected={@period == "24h"}>24 hours</option>
              <option value="3d" selected={@period == "3d"}>3 days</option>
              <option value="7d" selected={@period == "7d"}>7 days</option>
              <option value="14d" selected={@period == "14d"}>14 days</option>
              <option value="30d" selected={@period == "30d"}>30 days</option>
            </select>
          </form>
        </div>
        <div class="mt-4">
          <canvas
            id={"#{@id}-chart-#{@period}"}
            phx-hook="StackedBarChart"
            data-chart-data={Jason.encode!(@chart_data)}
            class="w-full h-48"
          >
          </canvas>
        </div>
      </div>
    </div>
    """
  end
end
