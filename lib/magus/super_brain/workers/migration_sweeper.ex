defmodule Magus.SuperBrain.Workers.MigrationSweeper do
  @moduledoc """
  Oban cron worker that rebuilds Layer 2 super graphs whose
  `CanonicalEntity.migration_marker` falls behind
  `Magus.SuperBrain.Migration.canonical_version/0`.

  ## Why

  Layer 2 graph identity (the `CanonicalId` hash and surrounding
  aggregation logic) is not under Postgres migration control: it lives
  in FalkorDB nodes that have no schema enforcement. A change to that
  formula leaves existing graphs internally consistent but inconsistent
  with new writes, which causes split canonicals and missing
  cross-source unification until the graph is rebuilt.

  Pre-this-worker, the rebuild was a manual deploy step per accessor
  (`mix super_brain.rebuild --graph super:user:<uid>`). Manageable for
  small user counts; operationally painful otherwise. This worker
  automates the sweep.

  ## How

  1. Read every `SuperGraph` row whose `last_build_status` is not
     `:building` (don't double up on an in-flight rebuild).
  2. For each, probe the live FalkorDB graph with a single COUNT query
     that filters for nodes whose `migration_marker` is `NULL` or
     `< canonical_version`. Any non-zero count classifies the graph
     as stale.
  3. Take the first `@max_enqueues_per_tick` stale rows (configurable
     via `:super_brain_migration_sweeper, :max_enqueues_per_tick`) and
     enqueue `BuildSuperFull` for each. The rate cap keeps a fresh
     deploy from saturating the `:super_brain_extraction` queue with
     thousands of simultaneous rebuilds.
  4. Emit `[:super_brain, :migration, :progress]` telemetry so
     operators can dashboard convergence.

  Probes against non-existent graphs return 0 stale and the row is
  classified `current` (nothing to migrate). Probe errors are counted
  separately and surfaced in the telemetry payload; they do not block
  other rows.

  ## Layer 1 staleness

  Entity (Layer 1) staleness is intentionally NOT handled here. A
  Layer 1 rebuild re-runs LLM extraction for every resource in the
  graph, which is expensive and unsafe to auto-trigger at scale.
  Operators force-rebuild via `mix super_brain.rebuild --graph
  <layer1>`; natural re-extraction on content edits also heals
  individual nodes. See `Magus.SuperBrain.Migration` for the version
  registry and the rules for bumping `entity_version/0` vs
  `canonical_version/0`.

  ## Lifecycle

  Once every Layer 2 graph carries the current marker, the sweeper is
  a no-op (one COUNT query per accessor per tick). The cron stays
  scheduled so the next time `canonical_version/0` is bumped, the same
  mechanism rebuilds the now-stale graphs without any deploy steps.
  """

  use Oban.Worker, queue: :super_brain_extraction, max_attempts: 1

  alias Magus.SuperBrain.{FalkorValues, Migration, SuperGraph}
  alias Magus.SuperBrain.Telemetry, as: SBTelemetry
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query
  require Logger

  @default_max_enqueues_per_tick 20

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{}) do
    current = Migration.canonical_version()
    max_per_tick = max_enqueues_per_tick()

    rows =
      SuperGraph
      |> Ash.Query.filter(last_build_status != :building)
      |> Ash.read!(authorize?: false)

    %{stale: stale, current_count: current_count, probe_errors: probe_errors} =
      classify_rows(rows, current)

    selected = Enum.take(stale, max_per_tick)

    Enum.each(selected, &enqueue_rebuild/1)

    SBTelemetry.migration_progress(%{
      current_version: current,
      total_rows: length(rows),
      stale_rows: length(stale),
      enqueued: length(selected),
      current_marker_rows: current_count,
      probe_errors: probe_errors
    })

    if stale != [] do
      Logger.info(
        "MigrationSweeper: enqueued #{length(selected)}/#{length(stale)} stale Layer 2 graphs " <>
          "(canonical_version=#{current}, total_rows=#{length(rows)}, probe_errors=#{probe_errors})"
      )
    end

    :ok
  end

  defp classify_rows(rows, current) do
    Enum.reduce(
      rows,
      %{stale: [], current_count: 0, probe_errors: 0},
      fn row, acc ->
        case probe_stale_count(row.graph_name, current) do
          {:ok, 0} ->
            %{acc | current_count: acc.current_count + 1}

          {:ok, n} when n > 0 ->
            %{acc | stale: [row | acc.stale]}

          {:error, reason} ->
            Logger.warning(
              "MigrationSweeper: probe failed for #{row.graph_name}: #{inspect(reason)}"
            )

            %{acc | probe_errors: acc.probe_errors + 1}
        end
      end
    )
  end

  defp probe_stale_count(graph_name, current) do
    cypher = """
    MATCH (c:CanonicalEntity)
    WHERE c.migration_marker IS NULL OR c.migration_marker < $v
    RETURN count(c) AS n
    """

    case Magus.Graph.query(graph_name, cypher, %{v: current}) do
      {:ok, %{rows: [[n] | _]}} ->
        {:ok, FalkorValues.parse_number(n, 0) |> round_to_int()}

      {:ok, _} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp round_to_int(n) when is_integer(n), do: n
  defp round_to_int(n) when is_float(n), do: round(n)
  defp round_to_int(_), do: 0

  defp enqueue_rebuild(row) do
    args = %{
      "accessor_type" => Atom.to_string(row.accessor_type),
      "user_id" => row.user_id,
      "workspace_id" => row.workspace_id
    }

    case args |> BuildSuperFull.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "MigrationSweeper: enqueue BuildSuperFull failed for #{row.graph_name}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp max_enqueues_per_tick do
    Application.get_env(:magus, :super_brain_migration_sweeper, [])
    |> Keyword.get(:max_enqueues_per_tick, @default_max_enqueues_per_tick)
  end
end
