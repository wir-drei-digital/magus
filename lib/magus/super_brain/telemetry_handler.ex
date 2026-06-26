defmodule Magus.SuperBrain.TelemetryHandler do
  @moduledoc """
  Logger-backed handler for every event the Super Brain emits.

  `Magus.SuperBrain.Telemetry` is the producer registry; this module is
  the consumer that turns those events into structured log lines so a
  fresh prod deploy is not blind during the first hour. Logger metadata
  on each line carries the event payload, so a log aggregator (Fly
  logs, Datadog, etc.) can index by `super_brain_event`,
  `super_brain_user_id`, `super_brain_graph_name`, etc. without parsing
  the message.

  This is intentionally the minimum viable sink: it makes events
  searchable in whatever log destination the app already uses. A richer
  reporter (Telemetry.Metrics + Prometheus exporter, AppSignal, etc.)
  can be added later without touching producers, by attaching alongside
  this handler.

  ## Levels

  | Event family | Level | Why |
  |--------------|-------|-----|
  | `*.exception` (span error) | `:error` | These are unexpected failures. |
  | `embedder.failure` | `:warning` | Degraded extraction quality if persistent. |
  | `*.stop` (span ok) | `:info` | Normal completion with timing. |
  | `budget.exhausted` | `:info` | Expected behavior at quota; surface for billing. |
  | `drift.detected` | `:info` | Normal during workspace membership changes. |
  | `migration.progress` (stale > 0) | `:info` | Migration is in progress. |
  | `migration.progress` (stale = 0) | `:debug` | Steady-state no-op. |
  | `extraction.sparse_edges` | `:debug` | Observability for tuning the prompt. |
  | `sanitizer.*` | `:debug` | Observability for ontology coverage. |

  ## Detach

  The handler attaches once at `Magus.Application.start/2` time and
  stays attached for the lifetime of the BEAM. `detach/0` is provided
  for tests that want to opt out of the global handler before
  attaching their own.
  """

  require Logger

  @handler_id "magus-super-brain-telemetry-handler"

  @events [
    [:super_brain, :extract, :stop],
    [:super_brain, :extract, :exception],
    [:super_brain, :build_super_full, :stop],
    [:super_brain, :build_super_full, :exception],
    [:super_brain, :build_super_incremental, :stop],
    [:super_brain, :build_super_incremental, :exception],
    [:super_brain, :retrieval, :stop],
    [:super_brain, :retrieval, :exception],
    [:super_brain, :embedder, :failure],
    [:super_brain, :sanitizer, :predicate_fallback],
    [:super_brain, :sanitizer, :type_fallback],
    [:super_brain, :sanitizer, :ambiguous_edge_endpoint],
    [:super_brain, :budget, :exhausted],
    [:super_brain, :drift, :detected],
    [:super_brain, :extraction, :sparse_edges],
    [:super_brain, :migration, :progress]
  ]

  @doc "List of events this handler subscribes to. Useful for tests and docs."
  def events, do: @events

  @doc """
  Attach the handler to all known Super Brain events.

  Safe to call multiple times: a second call with the same id returns
  `{:error, :already_exists}`, which is treated as a successful
  attachment by callers.
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler. Safe to call when not attached."
  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Span events: :stop on success, :exception on failure
  # ---------------------------------------------------------------------------

  @doc false
  def handle_event([:super_brain, kind, :stop], measurements, metadata, _config) do
    base =
      Map.merge(
        metadata_for_log(metadata),
        %{super_brain_event: "#{kind}.stop", duration_ms: duration_ms(measurements)}
      )

    # A span `:stop` fires on any normal return, including a `{:error, _}`
    # result. Producers that tag `:outcome` in the stop metadata let us log
    # failures as warnings instead of a misleading "ok". Producers that do not
    # tag it keep the prior "ok" behavior.
    case Map.get(metadata, :outcome) do
      :error ->
        Logger.warning(
          "super_brain.#{kind} failed reason=#{Map.get(metadata, :error_reason)}",
          Map.put(base, :super_brain_event, "#{kind}.error")
        )

      :cancelled ->
        Logger.info(
          "super_brain.#{kind} cancelled reason=#{Map.get(metadata, :error_reason)}",
          Map.put(base, :super_brain_event, "#{kind}.cancelled")
        )

      _ ->
        Logger.info("super_brain.#{kind} ok", base)
    end
  end

  def handle_event([:super_brain, kind, :exception], measurements, metadata, _config) do
    Logger.error(
      "super_brain.#{kind} exception kind=#{inspect(Map.get(metadata, :kind))} " <>
        "reason=#{inspect(Map.get(metadata, :reason))}",
      Map.merge(
        metadata_for_log(metadata),
        %{
          super_brain_event: "#{kind}.exception",
          duration_ms: duration_ms(measurements)
        }
      )
    )
  end

  # ---------------------------------------------------------------------------
  # One-shot counter events
  # ---------------------------------------------------------------------------

  def handle_event([:super_brain, :embedder, :failure], _measurements, metadata, _config) do
    Logger.warning(
      "super_brain.embedder.failure reason=#{inspect(Map.get(metadata, :reason))}",
      Map.put(metadata_for_log(metadata), :super_brain_event, "embedder.failure")
    )
  end

  def handle_event([:super_brain, :budget, :exhausted], _measurements, metadata, _config) do
    Logger.info(
      "super_brain.budget.exhausted user_id=#{Map.get(metadata, :user_id)} " <>
        "date=#{Map.get(metadata, :date)}",
      Map.put(metadata_for_log(metadata), :super_brain_event, "budget.exhausted")
    )
  end

  def handle_event([:super_brain, :drift, :detected], _measurements, metadata, _config) do
    Logger.info(
      "super_brain.drift.detected",
      Map.put(metadata_for_log(metadata), :super_brain_event, "drift.detected")
    )
  end

  def handle_event([:super_brain, :extraction, :sparse_edges], measurements, metadata, _config) do
    Logger.debug(
      "super_brain.extraction.sparse_edges entities=#{Map.get(measurements, :entity_count)} " <>
        "edges=#{Map.get(measurements, :edge_count)}",
      metadata_for_log(metadata)
      |> Map.merge(measurements)
      |> Map.put(:super_brain_event, "extraction.sparse_edges")
    )
  end

  def handle_event([:super_brain, :sanitizer, kind], _measurements, metadata, _config) do
    Logger.debug(
      "super_brain.sanitizer.#{kind}",
      Map.put(metadata_for_log(metadata), :super_brain_event, "sanitizer.#{kind}")
    )
  end

  def handle_event([:super_brain, :migration, :progress], measurements, metadata, _config) do
    stale = Map.get(measurements, :stale_rows, 0)
    total = Map.get(measurements, :total_rows, 0)
    enqueued = Map.get(measurements, :enqueued, 0)
    probe_errors = Map.get(measurements, :probe_errors, 0)
    current_version = Map.get(metadata, :current_version)

    level = if stale > 0, do: :info, else: :debug

    Logger.log(
      level,
      "super_brain.migration.progress version=#{current_version} " <>
        "stale=#{stale}/#{total} enqueued=#{enqueued} probe_errors=#{probe_errors}",
      metadata_for_log(metadata)
      |> Map.merge(measurements)
      |> Map.put(:super_brain_event, "migration.progress")
    )
  end

  # Catch-all: keeps a single handler resilient if a new producer adds a
  # documented event but forgets to wire a clause here. We still log so
  # the event surfaces, just at debug level since we can't pick a
  # better one without knowing the shape.
  def handle_event([:super_brain | _] = name, measurements, metadata, _config) do
    Logger.debug(
      "super_brain.unhandled_event #{Enum.join(name, ".")}",
      metadata_for_log(metadata)
      |> Map.merge(measurements)
      |> Map.put(:super_brain_event, "unhandled:#{Enum.join(name, ".")}")
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp duration_ms(%{duration: duration}) when is_integer(duration) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp duration_ms(_), do: nil

  # Logger metadata must be a keyword list or map of small terms. We
  # forward a curated set of well-known metadata keys plus a stringified
  # fallback for anything else, so a verbose payload (e.g. a large
  # `reason` term) is captured but does not pollute the indexer with
  # raw Elixir data structures.
  @forwarded_keys [
    :user_id,
    :workspace_id,
    :graph_name,
    :resource_id,
    :resource_type,
    :worker,
    :accessor_type
  ]

  defp metadata_for_log(metadata) when is_map(metadata) do
    Map.take(metadata, @forwarded_keys)
  end

  defp metadata_for_log(_), do: %{}
end
