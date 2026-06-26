defmodule Magus.Brain.Migrations.BackfillSources do
  @moduledoc """
  Phase B backfill worker: for each `:source` block in `brain_blocks`,
  upsert a corresponding `Magus.Brain.Source` row keyed by
  `(brain_id, url)`. Aggregates any child paragraph blocks (created by
  the legacy `SourceIngester`) into `Source.ingested_content`.

  Ingest-state mapping from legacy block metadata:

    * `metadata["ingested"] == true` → `ingest_status: :ingested`,
      `ingested_at` = block.updated_at
    * `metadata["ingestion_error"]` present → `ingest_status: :failed`,
      `ingest_error` = the error string
    * Neither → `ingest_status: :pending`

  Idempotent: re-running upserts on the unique `(brain_id, url)` index
  and only inserts rows whose `(brain_id, url)` pair doesn't already
  exist. To keep the worker progress-trackable without scanning the
  whole source-block table every tick, batches the next 50 source-block
  ids past the high-water mark of inserted Source rows; once every
  `:source` block has been visited the worker does zero work.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Ash.Query
  require Logger

  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    blocks = pending_source_blocks(batch_size)
    Enum.each(blocks, &backfill_one/1)
    {:ok, length(blocks)}
  end

  # A source block needs backfill when no `Magus.Brain.Source` row exists
  # for `(brain.id, content->>'url')`. Joined through brain_pages to
  # resolve brain_id; LEFT JOIN to brain_sources to filter out blocks
  # whose URL is already a Source row. UUIDs come back from this raw
  # table query as 16-byte binaries; we keep them as binaries internally
  # (other raw queries below take binaries) and dump-to-string only at
  # the Ash boundary in `backfill_one/1`.
  defp pending_source_blocks(limit) do
    from(b in "brain_blocks",
      join: p in "brain_pages",
      on: p.id == b.page_id,
      left_join: s in "brain_sources",
      on: s.brain_id == p.brain_id and s.url == fragment("?->>'url'", b.content),
      where: b.type == "source",
      where: is_nil(s.id),
      where: not is_nil(fragment("?->>'url'", b.content)),
      where: fragment("?->>'url'", b.content) != "",
      select: %{
        id: b.id,
        page_id: b.page_id,
        brain_id: p.brain_id,
        content: b.content,
        metadata: b.metadata,
        updated_at: b.updated_at
      },
      limit: ^limit,
      order_by: [asc: b.inserted_at]
    )
    |> Repo.all()
  end

  defp load_uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp load_uuid(s) when is_binary(s), do: s

  defp backfill_one(block) do
    url = block.content["url"]
    {status, ingest_error, ingested_at} = derive_ingest_state(block.metadata, block.updated_at)
    ingested_content = aggregate_child_paragraphs(block.id)

    attrs = %{
      brain_id: load_uuid(block.brain_id),
      url: url,
      title: block.content["title"],
      description: block.content["description"],
      author: block.content["author"],
      source_type: coerce_source_type(block.content["source_type"]),
      ingest_status: status,
      ingest_error: ingest_error,
      ingested_at: ingested_at,
      ingested_content: ingested_content
    }

    changeset = Ash.Changeset.for_create(Magus.Brain.Source, :from_legacy_block, attrs)

    case Ash.create(changeset, authorize?: false) do
      {:ok, _source} ->
        :ok

      {:error, error} ->
        if unique_violation?(error) do
          # Two source blocks in the same brain pointing at the same URL —
          # the first insert wins, this one collides on the (brain_id, url)
          # unique index. Expected for batched backfill; silent skip.
          :ok
        else
          Logger.warning("BackfillSources: create failed for #{url}: #{inspect(error)}")
          :ok
        end
    end
  rescue
    e ->
      Logger.warning(
        "BackfillSources: failed for block #{inspect(block.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp unique_violation?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} when is_list(vars) ->
        Keyword.get(vars, :constraint_type) == :unique

      _ ->
        false
    end)
  end

  defp unique_violation?(_), do: false

  defp derive_ingest_state(metadata, updated_at) when is_map(metadata) do
    cond do
      Map.get(metadata, "ingestion_error") ->
        {:failed, to_string(metadata["ingestion_error"]), nil}

      Map.get(metadata, "ingested") == true ->
        {:ingested, nil, updated_at}

      true ->
        {:pending, nil, nil}
    end
  end

  defp derive_ingest_state(_, _), do: {:pending, nil, nil}

  defp coerce_source_type(nil), do: :web
  defp coerce_source_type(""), do: :web

  defp coerce_source_type(value) when is_binary(value) do
    normalized =
      value |> String.downcase() |> String.to_existing_atom()

    if normalized in [:web, :paper, :book, :video, :pdf, :feed, :other],
      do: normalized,
      else: :other
  rescue
    ArgumentError -> :other
  end

  defp coerce_source_type(value) when is_atom(value), do: value

  # Children of legacy :source blocks are paragraphs with parent_block_id
  # pointing at the source. We aggregate by position and join with double-
  # newlines so the result matches what `SourceIngester.fetch_url` would
  # have produced.
  defp aggregate_child_paragraphs(source_block_id) do
    from(b in "brain_blocks",
      where: b.parent_block_id == ^source_block_id,
      where: b.type == "paragraph",
      order_by: [asc: b.position],
      select: fragment("?->>'text'", b.content)
    )
    |> Repo.all()
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> nil
      paragraphs -> Enum.join(paragraphs, "\n\n")
    end
  end
end
