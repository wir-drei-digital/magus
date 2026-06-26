defmodule Magus.Brain.Source.IngestWorker do
  @moduledoc """
  Phase C4 worker. For one `Magus.Brain.Source` row in `:pending` (or
  `:failed`, to allow retries), fetches the URL via
  `Magus.Brain.SourceIngester.fetch_url/1`, persists the extracted text
  to `ingested_content`, advances the ingest state machine, and enqueues
  `Magus.Brain.Source.ChunkWorker` so embeddings get built downstream.

  Enqueued by `Magus.Brain.Source.Changes.EnqueueIngestWorker` from the
  `:create` and `:from_legacy_block` after-actions. Sources already in
  `:ingested` or `:ingesting` are no-ops so concurrent enqueues don't
  re-fetch a URL.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  alias Magus.Brain
  alias Magus.Brain.SourceIngester

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    case Brain.get_source(source_id, authorize?: false) do
      {:ok, source} ->
        case source.ingest_status do
          status when status in [:pending, :failed] -> ingest(source)
          # Already running or done; another worker will (or did) handle
          # this row.
          _ -> :ok
        end

      # Source got deleted between enqueue and perform — treat as a no-op
      # so the job retires successfully instead of clogging the queue.
      {:error, _} ->
        :ok
    end
  end

  defp ingest(source) do
    mark_ingesting(source)

    case SourceIngester.fetch_url(source.url) do
      {:ok, %{title: fetched_title, content: content}} ->
        attrs = %{
          ingested_content: content,
          ingest_status: :ingested,
          ingest_error: nil,
          ingested_at: DateTime.utc_now()
        }

        # Only override the row's title if the user/agent never set one.
        attrs =
          if blank?(source.title) and not blank?(fetched_title) do
            Map.put(attrs, :title, fetched_title)
          else
            attrs
          end

        case Brain.ingest_source(source, attrs, authorize?: false) do
          {:ok, _source} ->
            enqueue_chunker(source.id)
            :ok

          {:error, reason} ->
            Logger.warning(
              "Brain.Source.IngestWorker: ingest update failed for #{inspect(source.id)}: " <>
                inspect(reason)
            )

            # Re-raise so Oban records the attempt and retries.
            {:error, reason}
        end

      {:error, reason} ->
        _ =
          Brain.ingest_source(
            source,
            %{
              ingest_status: :failed,
              ingest_error: inspect(reason)
            },
            authorize?: false
          )

        # Returning :ok keeps the job from retrying transient HTTP errors
        # in tight succession. Retries happen via a manual enqueue or a
        # subsequent update on the source.
        :ok
    end
  end

  defp mark_ingesting(source) do
    Brain.ingest_source(source, %{ingest_status: :ingesting}, authorize?: false)
  end

  defp enqueue_chunker(source_id) do
    %{"source_id" => source_id}
    |> Magus.Brain.Source.ChunkWorker.new()
    |> Oban.insert!()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
