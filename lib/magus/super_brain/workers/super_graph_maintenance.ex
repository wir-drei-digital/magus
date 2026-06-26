defmodule Magus.SuperBrain.Workers.SuperGraphMaintenance do
  @moduledoc """
  Catches failed and stale super graph builds.

  Runs at 04:00 UTC daily, 30 minutes after `NightlyBuildSuperScheduler`,
  so any builds that failed during the nightly tick get re-enqueued. Also
  picks up super graphs that have not been rebuilt in over 36 hours (e.g.,
  app downtime missed the nightly window).

  BuildSuperFull's per-accessor advisory lock prevents duplicate concurrent
  runs even if this worker enqueues the same accessor that the nightly
  scheduler already enqueued.
  """

  use Oban.Worker, queue: :super_brain_extraction, max_attempts: 1

  alias Magus.SuperBrain.SuperGraph
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query
  require Logger

  @stale_threshold_hours 36

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{}) do
    requeue_failed()
    requeue_stale()
    :ok
  end

  defp requeue_failed do
    rows =
      SuperGraph
      |> Ash.Query.filter(last_build_status == :failed)
      |> Ash.read!(authorize?: false)

    Enum.each(rows, &enqueue_build/1)
    Logger.info("SuperGraphMaintenance re-enqueued #{length(rows)} failed builds")
  end

  defp requeue_stale do
    threshold = DateTime.add(DateTime.utc_now(), -@stale_threshold_hours * 3600, :second)

    rows =
      SuperGraph
      |> Ash.Query.filter(last_built_at < ^threshold)
      |> Ash.read!(authorize?: false)

    Enum.each(rows, &enqueue_build/1)
    Logger.info("SuperGraphMaintenance re-enqueued #{length(rows)} stale builds")
  end

  defp enqueue_build(row) do
    args = %{
      "accessor_type" => Atom.to_string(row.accessor_type),
      "user_id" => row.user_id,
      "workspace_id" => row.workspace_id
    }

    _ = BuildSuperFull.new(args) |> Oban.insert()
  end
end
