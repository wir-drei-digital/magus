defmodule Magus.Integrations.ProcessIngestion do
  @moduledoc """
  Processes incoming data for data source providers (logs, RSS, etc.).

  Unlike ProcessWebhook (which creates InputMessage records for conversation routing),
  this creates IngestionEntry records and runs threshold checks.
  """

  require Logger

  alias Magus.Integrations
  alias Magus.Integrations.ThresholdChecker

  @doc """
  Process a data source webhook payload.

  1. Parse payload via provider's parse_ingestion_payload/2
  2. Classify each entry via provider's classify/1
  3. Generate content hashes and bulk insert IngestionEntry records
  4. Run ThresholdChecker

  Returns {:ok, %{ingested: count}} or {:error, reason}.
  """
  def run(provider_module, integration, payload, headers) do
    with {:ok, raw_entries} <- provider_module.parse_ingestion_payload(payload, headers) do
      classify_and_store(provider_module, integration, raw_entries)
    end
  end

  @doc """
  Process pre-parsed entries directly (used by PollDataSource to avoid double-parsing).
  """
  def run_with_entries(provider_module, integration, raw_entries) when is_list(raw_entries) do
    classify_and_store(provider_module, integration, raw_entries)
  end

  defp classify_and_store(provider_module, integration, raw_entries) do
    entries =
      raw_entries
      |> Enum.map(fn entry ->
        classification = provider_module.classify(entry)
        severity = classification.severity || entry[:severity] || :info
        title = classification.title || entry[:title]

        content = entry[:content] || ""
        content_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        %{
          user_integration_id: integration.id,
          user_id: integration.user_id,
          source_type: detect_source_type(provider_module),
          external_id: entry[:external_id],
          severity: severity,
          title: title,
          content: content,
          metadata: entry[:metadata] || %{},
          occurred_at: entry[:occurred_at] || DateTime.utc_now(),
          content_hash: content_hash
        }
      end)

    # Bulk insert, skipping duplicates
    {inserted, _skipped} =
      Enum.reduce(entries, {[], []}, fn attrs, {ok, skip} ->
        case Integrations.create_ingestion_entry(attrs, authorize?: false) do
          {:ok, entry} ->
            {[entry | ok], skip}

          {:error, error} ->
            # Log non-duplicate errors for debugging
            Logger.warning("Ingestion entry insert failed: #{inspect(error)}")
            {ok, [attrs | skip]}
        end
      end)

    # Run threshold check with successfully inserted entries
    if inserted != [] do
      ThresholdChecker.check(integration, inserted, provider_module)
    end

    {:ok, %{ingested: length(inserted)}}
  end

  defp detect_source_type(module) do
    case module.key() do
      :log_source -> :log
      :rss_source -> :rss
      _ -> :log
    end
  end
end
