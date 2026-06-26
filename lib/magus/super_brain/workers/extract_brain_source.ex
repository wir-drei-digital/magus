defmodule Magus.SuperBrain.Workers.ExtractBrainSource do
  @moduledoc """
  Extracts entities and edges from a brain Source's ingested content into
  the source's owning brain graph (`brain:<brain_id>`).

  Mirrors `Magus.SuperBrain.Workers.ExtractFileChunk`: a thin `load/1`
  over the shared `ExtractBase` pipeline. Only `:ingested` sources with
  non-empty `ingested_content` are extractable; pending / failed sources
  are skipped. Enqueued from `Source.ingest`'s after_action.
  """

  use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

  @extractor_version "brain_source_extract_worker@2026-06-01"

  @impl true
  def extractor_version, do: @extractor_version

  @impl true
  def load(%{"resource_id" => source_id}) when is_binary(source_id) do
    with {:ok, source} <-
           Ash.get(Magus.Brain.Source, source_id, load: [:brain], authorize?: false),
         :ok <- check_ingested(source),
         {:ok, user_id} <- resolve_user_id(source) do
      {:ok,
       %{
         user_id: user_id,
         raw_text: source.ingested_content || "",
         graph_name: "brain:#{source.brain_id}",
         resource_type: :brain_source,
         resource_id: source.id,
         source_weight: 0.85,
         # NB: the pipeline reserves the `source_id` entity property for the
         # Episode id (used by re-extraction + incremental-build filters), so
         # carry the brain Source's id under a non-colliding key, mirroring
         # ExtractFileChunk's `file_id`/`chunk_id` provenance convention.
         extra_node_props: %{brain_source_id: source.id}
       }}
    else
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :source_not_found}
      {:error, _} = err -> err
    end
  end

  def load(_), do: {:error, :missing_resource_id}

  defp check_ingested(%{ingest_status: :ingested, ingested_content: c})
       when is_binary(c) and c != "",
       do: :ok

  defp check_ingested(_), do: {:error, :source_not_ingested}

  defp resolve_user_id(%{brain: %{user_id: uid}}) when is_binary(uid), do: {:ok, uid}
  defp resolve_user_id(_), do: {:error, :source_user_not_resolvable}
end
