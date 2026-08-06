defmodule Magus.Chat.Workers.SweepUsageReconciliation do
  @moduledoc """
  Daily sweep for the two recoverable reconciliation states (magus-abt):

    * `:unavailable` rows younger than 30 days flip back to `:pending` and
      re-enqueue reconciliation. OpenRouter generation stats sometimes
      materialize long after the reconciliation worker's poll window, so
      giving up permanently after 12 polls left real token cost unbilled.
    * `:reconciled_uncharged` rows re-attempt the usage charge with the same
      idempotent meter identifier and flip to `:reconciled` on success.

  Emits a `[:magus, :usage, :reconciliation_sweep]` telemetry snapshot so the
  remaining liability is visible rather than log-only.
  """

  use Oban.Worker, queue: :usage_reconciliation, max_attempts: 3

  require Logger
  require Ash.Query

  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Chat.Workers.ReconcileOpenRouterUsage
  alias Magus.Usage.MessageUsage

  @retry_window_days 30
  @batch_limit 500

  @impl Oban.Worker
  def perform(_job) do
    retried = retry_unavailable()
    {recovered, still_uncharged} = recover_uncharged()

    :telemetry.execute(
      [:magus, :usage, :reconciliation_sweep],
      %{
        unavailable_retried: retried,
        uncharged_recovered: recovered,
        uncharged_remaining: still_uncharged
      },
      %{}
    )

    Logger.info(
      "SweepUsageReconciliation: retried #{retried} unavailable, " <>
        "recovered #{recovered} uncharged, #{still_uncharged} uncharged remaining"
    )

    :ok
  end

  defp retry_unavailable do
    cutoff = DateTime.add(DateTime.utc_now(), -@retry_window_days, :day)

    MessageUsage
    |> Ash.Query.filter(reconciliation_status == :unavailable and inserted_at > ^cutoff)
    |> Ash.Query.filter(not is_nil(provider_generation_id))
    |> Ash.Query.limit(@batch_limit)
    |> Ash.read!(authorize?: false)
    |> Enum.count(fn usage ->
      with {:ok, _} <- Ash.update(usage, %{}, action: :retry_reconciliation, authorize?: false),
           {:ok, _} <- ReconcileOpenRouterUsage.enqueue(usage.id) do
        true
      else
        _ -> false
      end
    end)
  end

  defp recover_uncharged do
    rows =
      MessageUsage
      |> Ash.Query.filter(reconciliation_status == :reconciled_uncharged)
      |> Ash.Query.limit(@batch_limit)
      |> Ash.read!(authorize?: false)

    recovered =
      Enum.count(rows, fn usage ->
        # Same identifier the original attempt used, so the metering sink
        # dedupes if the failure happened after the meter event landed.
        case UsageRecorder.record_billable_cost(usage.user_id, usage.total_cost,
               meter_identifier: "usage-#{usage.id}-reconcile"
             ) do
          :ok ->
            Ash.update(usage, %{}, action: :mark_reconciliation_charged, authorize?: false)
            true

          {:error, _} ->
            false
        end
      end)

    {recovered, length(rows) - recovered}
  end
end
