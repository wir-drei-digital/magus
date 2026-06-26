defmodule Magus.SuperBrain.Telemetry do
  @moduledoc """
  Canonical telemetry event names for the Super Brain subsystem.

  Pre-Wave-2 zero telemetry events existed; operators were blind to
  degradation modes (embedder outages, sanitizer fallbacks, drift
  events, budget exhaustion). This module is the single source of
  truth for event names so handlers attaching from a release config
  do not encode names the producer side has drifted from.

  ## Span events

  These follow the `:telemetry.span/3` convention: every span emits a
  `:start`, then exactly one of `:stop` (on `:ok` returns) or
  `:exception` (on raise/exit/throw). Measurements always carry
  `:system_time` on `:start` and `:duration` on `:stop`/`:exception`
  (in native time units).

    * `[:super_brain, :extract, :start | :stop | :exception]`
      wraps `Magus.SuperBrain.Workers.ExtractBase.do_run/3`.
      Metadata: `%{worker: module, user_id, graph_name, resource_type,
        resource_id}`.

    * `[:super_brain, :build_super_full, :start | :stop | :exception]`
      wraps `BuildSuperFull.perform/1` body.
      Metadata: `%{accessor_type, user_id, workspace_id}`.

    * `[:super_brain, :build_super_incremental, :start | :stop | :exception]`
      wraps `BuildSuperIncremental.perform/1` body.
      Metadata: `%{accessor_type, user_id, workspace_id}`.

    * `[:super_brain, :retrieval, :start | :stop | :exception]`
      wraps `Magus.SuperBrain.Retrieval.search/2`.
      Metadata: `%{user_id, workspace_id}`.

  ## Counter events

  These are one-shot events with `%{count: 1}` measurements. Use them
  to instrument failure paths that don't return through a span.

    * `[:super_brain, :embedder, :failure]`
      Metadata: `%{reason}` (the embedder error term).

    * `[:super_brain, :sanitizer, :predicate_fallback]`
      Metadata: `%{from_predicate: string}` (the predicate the
      sanitizer could not classify; replaced by the `:relates_to`
      fallback).

    * `[:super_brain, :sanitizer, :type_fallback]`
      Metadata: `%{from_type: string}` (the entity type the sanitizer
      could not classify; replaced by the `:concept` fallback).

    * `[:super_brain, :budget, :exhausted]`
      Metadata: `%{user_id, date}` (the day the per-user extraction
      ceiling tripped).

    * `[:super_brain, :drift, :detected]`
      Metadata: `%{accessor_type, user_id, workspace_id}`. Emitted by
      `BuildSuperIncremental` when the read-set snapshot does not
      match the current read-set.

    * `[:super_brain, :extraction, :sparse_edges]`
      Metadata: `%{entity_count, edge_count, user_id}`. Emitted by
      `Magus.SuperBrain.Extraction.extract/2` when the LLM returns a
      batch with `entity_count >= 3 and edge_count < 2`. Iter5 Task 3.6
      observability only: nothing rejects or re-prompts on this signal.

    * `[:super_brain, :migration, :progress]`
      Measurements: `%{total_rows, stale_rows, enqueued,
      current_marker_rows, probe_errors}`. Metadata:
      `%{current_version}`. Emitted once per
      `Magus.SuperBrain.Workers.MigrationSweeper` tick.

  ## Usage

      :telemetry.span(
        [:super_brain, :build_super_full],
        %{accessor_type: :user, user_id: uid, workspace_id: nil},
        fn ->
          result = do_the_work()
          {result, %{}}
        end
      )

      Magus.SuperBrain.Telemetry.embedder_failure(reason)

  Tests can attach to events via `:telemetry_test.attach_event_handlers/2`.
  """

  @doc "Emit a one-shot embedder-failure counter."
  @spec embedder_failure(any()) :: :ok
  def embedder_failure(reason) do
    :telemetry.execute(
      [:super_brain, :embedder, :failure],
      %{count: 1},
      %{reason: reason}
    )
  end

  @doc "Emit a one-shot predicate-fallback counter."
  @spec sanitizer_predicate_fallback(String.t() | nil) :: :ok
  def sanitizer_predicate_fallback(from_predicate) do
    :telemetry.execute(
      [:super_brain, :sanitizer, :predicate_fallback],
      %{count: 1},
      %{from_predicate: from_predicate}
    )
  end

  @doc "Emit a one-shot type-fallback counter."
  @spec sanitizer_type_fallback(String.t() | nil) :: :ok
  def sanitizer_type_fallback(from_type) do
    :telemetry.execute(
      [:super_brain, :sanitizer, :type_fallback],
      %{count: 1},
      %{from_type: from_type}
    )
  end

  @doc "Emit a one-shot budget-exhausted counter."
  @spec budget_exhausted(String.t() | nil, Date.t() | nil) :: :ok
  def budget_exhausted(user_id, date) do
    :telemetry.execute(
      [:super_brain, :budget, :exhausted],
      %{count: 1},
      %{user_id: user_id, date: date}
    )
  end

  @doc "Emit a one-shot read-set-drift counter."
  @spec drift_detected(map()) :: :ok
  def drift_detected(metadata) when is_map(metadata) do
    :telemetry.execute(
      [:super_brain, :drift, :detected],
      %{count: 1},
      metadata
    )
  end

  @doc """
  Emit a `MigrationSweeper` tick progress event.

  `payload` must contain `:current_version` (metadata) plus the integer
  measurement keys `:total_rows`, `:stale_rows`, `:enqueued`,
  `:current_marker_rows`, `:probe_errors`. Missing measurements default
  to `0` so callers do not have to defensively zero-fill.
  """
  @spec migration_progress(map()) :: :ok
  def migration_progress(payload) when is_map(payload) do
    :telemetry.execute(
      [:super_brain, :migration, :progress],
      %{
        total_rows: Map.get(payload, :total_rows, 0),
        stale_rows: Map.get(payload, :stale_rows, 0),
        enqueued: Map.get(payload, :enqueued, 0),
        current_marker_rows: Map.get(payload, :current_marker_rows, 0),
        probe_errors: Map.get(payload, :probe_errors, 0)
      },
      Map.take(payload, [:current_version])
    )
  end
end
