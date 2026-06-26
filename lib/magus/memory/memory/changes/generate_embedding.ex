defmodule Magus.Memory.Memory.Changes.GenerateEmbedding do
  @moduledoc """
  Generates a vector embedding for the memory's summary.

  This change is triggered by AshOban when a memory has a summary.
  The embedding enables semantic search across memories.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      memory = changeset.data

      case generate_embedding(memory.summary) do
        {:ok, embedding} ->
          Ash.Changeset.force_change_attribute(changeset, :summary_embedding, embedding)

        {:error, reason} ->
          Logger.warning(
            "Failed to generate embedding for memory #{memory.id}: #{inspect(reason)}"
          )

          Ash.Changeset.add_error(changeset,
            field: :summary_embedding,
            message: "Failed to generate embedding"
          )
      end
    end)
  end

  defp generate_embedding(summary) when is_binary(summary) and summary != "" do
    case Magus.Files.EmbeddingModel.embed(summary) do
      {:ok, embedding} ->
        {:ok, Pgvector.new(embedding)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_embedding(_), do: {:error, :no_summary}
end
