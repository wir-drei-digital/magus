defmodule MagusWeb.Admin.Charts do
  @moduledoc """
  Chart.js payload builders shared by the admin analytics views.

  Turns the compact SQL rollups from `Magus.Usage.AdminStats` (one row per
  non-empty bucket/series) into the `%{labels: [...], datasets: [...]}` maps
  the StackedBarChart / DoughnutChart hooks expect, zero-filling empty buckets
  so the time axis is continuous.
  """

  @palette [
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

  @doc "The shared series palette; cycles when a chart has more series."
  def palette, do: @palette

  @doc "Color for the nth series (cycling through the palette)."
  def color_at(idx), do: Enum.at(@palette, rem(idx, length(@palette)))

  @doc """
  Stacked-bar payload over epoch-aligned time buckets.

  `rows` come from `AdminStats.bucketed_counts/3`: `%{bucket: DateTime,
  series: term, count: n}`. Buckets are generated from `:since` to now in
  `:bucket_seconds` steps so gaps render as zero.

  Options:

    * `:since` (required) — window start
    * `:bucket_seconds` (required) — must match the query's bucket size
    * `:label` (required) — `DateTime -> String` for the x-axis labels
    * `:series` — fixed series order (e.g. `[true, false]`); defaults to the
      distinct values found, sorted
    * `:series_label` — `term -> String`; defaults to `to_string/1` with nil
      as "Unknown"
    * `:series_color` — `term, index -> color`; defaults to the palette
  """
  def stacked_time_series(rows, opts) do
    bucket_seconds = Keyword.fetch!(opts, :bucket_seconds)
    since = Keyword.fetch!(opts, :since)
    label_fn = Keyword.fetch!(opts, :label)

    buckets = bucket_range(since, DateTime.utc_now(), bucket_seconds)
    by_series = Enum.group_by(rows, & &1.series)

    series_keys =
      Keyword.get_lazy(opts, :series, fn ->
        by_series |> Map.keys() |> Enum.sort_by(&to_string/1)
      end)

    series_label = Keyword.get(opts, :series_label, &default_series_label/1)
    series_color = Keyword.get(opts, :series_color, fn _key, idx -> color_at(idx) end)

    datasets =
      series_keys
      |> Enum.with_index()
      |> Enum.map(fn {key, idx} ->
        counts =
          Map.new(by_series[key] || [], fn row -> {DateTime.to_unix(row.bucket), row.count} end)

        %{
          label: series_label.(key),
          data: Enum.map(buckets, &Map.get(counts, &1, 0)),
          backgroundColor: series_color.(key, idx)
        }
      end)

    labels = Enum.map(buckets, fn unix -> unix |> DateTime.from_unix!() |> label_fn.() end)

    %{labels: labels, datasets: datasets}
  end

  @doc "Doughnut payload from parallel label/value lists."
  def doughnut(labels, values) do
    colors = labels |> Enum.with_index() |> Enum.map(fn {_, idx} -> color_at(idx) end)
    %{labels: labels, datasets: [%{data: values, backgroundColor: colors}]}
  end

  @doc ~S(Hour-of-day label, e.g. "14:00".)
  def hour_label(dt), do: Calendar.strftime(dt, "%H:00")

  @doc ~S(Weekday + hour label, e.g. "Tue 14:00".)
  def day_hour_label(dt), do: Calendar.strftime(dt, "%a %H:00")

  @doc ~S(Weekday + day-of-month label, e.g. "Tue 3".)
  def week_day_label(dt), do: "#{Calendar.strftime(dt, "%a")} #{dt.day}"

  @doc ~S(Month + day-of-month label, e.g. "Jun 3".)
  def month_day_label(dt), do: "#{Calendar.strftime(dt, "%b")} #{dt.day}"

  defp default_series_label(nil), do: "Unknown"
  defp default_series_label(key), do: to_string(key)

  # Epoch-aligned bucket starts covering [since, now], inclusive.
  defp bucket_range(since, now, bucket_seconds) do
    first = floor_unix(since, bucket_seconds)
    last = floor_unix(now, bucket_seconds)

    first
    |> Stream.iterate(&(&1 + bucket_seconds))
    |> Enum.take_while(&(&1 <= last))
  end

  defp floor_unix(dt, bucket_seconds) do
    unix = DateTime.to_unix(dt)
    unix - Integer.mod(unix, bucket_seconds)
  end
end
