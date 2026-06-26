defmodule Magus.Agents.Context.RagContext do
  @moduledoc """
  Builds automatic RAG context for AI agents.

  On every message, embeds the user's query and retrieves the most relevant
  document chunks. The results are injected into the system prompt so the
  LLM can answer from the user's documents without a tool call round-trip.

  The explicit `search_files` tool remains available for refined/follow-up
  searches with different queries.
  """

  require Logger

  alias Magus.Agents.Tools.Rag
  alias Magus.Files.EmbeddingModel

  @max_results 5

  @doc """
  Build RAG context for a conversation message.

  Resolves accessible file IDs, embeds the query, searches chunks, and
  formats as a system prompt section. Returns nil when no relevant context
  is found.

  Expects a map with `:query`, `:user` (the loaded user struct),
  plus the isolation/scope fields used by `Rag.resolve_file_ids/2`.
  """
  @spec build(map()) :: String.t() | nil
  def build(%{query: query, user: %{id: user_id} = user} = opts)
      when is_binary(query) and query != "" do
    opts = Map.put(opts, :user_id, to_string(user_id))
    file_ids = Rag.resolve_file_ids(opts, user)

    if file_ids == [] do
      nil
    else
      case resolve_query_embedding(opts, query) do
        {:ok, embedding} ->
          search_and_format(embedding, file_ids, user)

        {:error, :no_embedding} ->
          nil

        {:error, reason} ->
          Logger.warning("RAG context: embedding failed: #{inspect(reason)}")
          nil
      end
    end
  rescue
    e ->
      Logger.warning("RAG context failed: #{Exception.message(e)}")
      nil
  end

  def build(_), do: nil

  # Reuse a precomputed query embedding when the caller supplies one (the agent
  # context builder embeds the query once and shares it across retrievers). A
  # nil value means the upstream embed failed/timed out, so we skip RAG this
  # turn. When the key is absent, embed here (legacy callers and tests).
  defp resolve_query_embedding(opts, query) do
    case Map.fetch(opts, :query_embedding) do
      {:ok, embedding} when is_list(embedding) -> {:ok, embedding}
      {:ok, _} -> {:error, :no_embedding}
      :error -> EmbeddingModel.embed_query(query)
    end
  end

  defp search_and_format(embedding, file_ids, actor) do
    case Magus.Files.search_chunks(embedding, file_ids, @max_results, actor: actor) do
      {:ok, []} ->
        nil

      {:ok, chunks} ->
        chunks
        |> Ash.load!([file: [:name, knowledge_collection: [:name]]], actor: actor)
        |> Enum.reject(&is_nil(&1.file))
        |> format_chunks()

      {:error, reason} ->
        Logger.warning("RAG context: search failed: #{inspect(reason)}")
        nil
    end
  end

  defp format_chunks([]), do: nil

  defp format_chunks(chunks) do
    entries =
      Enum.map_join(chunks, "\n\n", fn chunk ->
        source = chunk.file.name

        source_label =
          case chunk.file.knowledge_collection do
            %{name: collection} when is_binary(collection) ->
              "#{source} (from #{collection})"

            _ ->
              source
          end

        """
        [Source: #{source_label}]
        #{chunk.content}\
        """
      end)

    """
    <relevant_documents>
    The following excerpts from the user's documents may be relevant to their message.
    Use this information to inform your response. Cite the source when using this information.

    #{entries}
    </relevant_documents>\
    """
  end
end
