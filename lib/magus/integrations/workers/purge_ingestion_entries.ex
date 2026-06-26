defmodule Magus.Integrations.Workers.PurgeIngestionEntries do
  @moduledoc """
  Daily Oban worker that deletes IngestionEntry records older than each
  integration's configured retention_days. Uses batch deletes to avoid
  long-running transactions.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1

  require Logger
  require Ash.Query

  @batch_size 1000
  @default_retention_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("PurgeIngestionEntries: starting retention cleanup")

    # Data source provider keys that support ingestion
    data_source_keys = [:log_source, :rss_source]

    total_purged =
      data_source_keys
      |> Enum.flat_map(&active_integrations_for_provider/1)
      |> Enum.map(&purge_for_integration/1)
      |> Enum.sum()

    Logger.info("PurgeIngestionEntries: purged #{total_purged} entries total")
    :ok
  end

  defp active_integrations_for_provider(provider_key) do
    case Magus.Integrations.UserIntegration
         |> Ash.Query.filter(provider_key == ^provider_key and status == :active)
         |> Ash.read(authorize?: false) do
      {:ok, integrations} -> integrations
      _ -> []
    end
  end

  defp purge_for_integration(integration) do
    retention_days = get_in(integration.config, ["retention_days"]) || @default_retention_days
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days * 86400, :second)

    purge_batch(integration.id, cutoff, 0)
  end

  defp purge_batch(integration_id, cutoff, total_purged) do
    query =
      Magus.Integrations.IngestionEntry
      |> Ash.Query.filter(user_integration_id == ^integration_id and occurred_at < ^cutoff)
      |> Ash.Query.limit(@batch_size)

    case Ash.read(query, authorize?: false) do
      {:ok, []} ->
        total_purged

      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          Ash.destroy!(entry, authorize?: false)
        end)

        purge_batch(integration_id, cutoff, total_purged + length(entries))
    end
  end
end
