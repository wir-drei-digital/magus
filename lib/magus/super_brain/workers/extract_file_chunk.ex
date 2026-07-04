defmodule Magus.SuperBrain.Workers.ExtractFileChunk do
  @moduledoc """
  Extracts entities and edges from file chunks into the file's owning user
  or workspace graph.

  Filters: parent file's `type` must be in [:document, :text, :email].
  Image and video files are skipped (no vision LLM in iter2).

  Routing:
    file.workspace_id == nil      ->  files:user:<file.user_id>
    file.workspace_id == ws_id    ->  files:workspace:<ws_id>

  The chunk's `file_id` and `chunk_id` are written as entity properties so
  retrieval can roll up to file-level provenance. The structural
  `(Chunk)-[:PART_OF]->(File)` edge is deferred to iter3 per the spec.

  Pipeline implemented by `Magus.SuperBrain.Workers.ExtractBase`. This module
  only implements the resource-specific `load/1` callback. The base handles
  fingerprint gating, budget killswitch, Episode lifecycle, MessageUsage
  writes, and graph writes.
  """

  use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

  @extractor_version "file_chunk_extract_worker@2026-07-04-claims"
  @extractable_file_types [:document, :text, :email]

  @impl true
  def extractor_version, do: @extractor_version

  @impl true
  def load(%{"resource_id" => chunk_id}) when is_binary(chunk_id) do
    with {:ok, chunk} <-
           Ash.get(Magus.Files.Chunk, chunk_id, load: [:file], authorize?: false),
         :ok <- check_file_type(chunk.file),
         {:ok, graph_name} <- route(chunk.file) do
      {:ok,
       %{
         user_id: chunk.file.user_id,
         raw_text: chunk.content || "",
         graph_name: graph_name,
         resource_type: :file_chunk,
         resource_id: chunk.id,
         source_weight: 1.0,
         extra_node_props: %{file_id: chunk.file_id, chunk_id: chunk.id}
       }}
    else
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :chunk_not_found}
      {:error, _} = err -> err
    end
  end

  def load(_), do: {:error, :missing_resource_id}

  # ---------------------------------------------------------------------------
  # File-type filter
  # ---------------------------------------------------------------------------

  defp check_file_type(%{type: type}) when type in @extractable_file_types, do: :ok
  defp check_file_type(_), do: {:error, :file_type_not_extractable}

  # ---------------------------------------------------------------------------
  # Graph routing
  # ---------------------------------------------------------------------------

  defp route(%{workspace_id: nil, user_id: uid}) when is_binary(uid) do
    {:ok, "files:user:#{uid}"}
  end

  defp route(%{workspace_id: ws_id}) when is_binary(ws_id) do
    {:ok, "files:workspace:#{ws_id}"}
  end

  defp route(_), do: {:error, :unrouteable_file}
end
