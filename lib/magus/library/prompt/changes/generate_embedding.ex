defmodule Magus.Library.Prompt.Changes.GenerateEmbedding do
  @moduledoc """
  Generates a vector embedding for the prompt content.

  Combines name, description, and content into a single text for embedding.
  This enables semantic similarity search across prompts.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      record = changeset.data
      text_to_embed = build_embedding_text(record, changeset)

      case generate_embedding(text_to_embed) do
        {:ok, embedding} ->
          Ash.Changeset.force_change_attribute(changeset, :embedding, embedding)

        {:error, reason} ->
          # Use name from changeset for logging since record.id may be nil for new records
          prompt_name = Ash.Changeset.get_attribute(changeset, :name) || record.name || "unknown"

          Logger.warning(
            "Failed to generate embedding for prompt '#{prompt_name}': #{inspect(reason)}"
          )

          # Don't fail the action, just log and continue without embedding
          changeset
      end
    end)
  end

  defp build_embedding_text(record, changeset) do
    # Get values from changeset if changed, otherwise from record
    name = Ash.Changeset.get_attribute(changeset, :name) || record.name
    description = Ash.Changeset.get_attribute(changeset, :description) || record.description
    content = Ash.Changeset.get_attribute(changeset, :content) || record.content

    [name, description, content]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp generate_embedding(text) when is_binary(text) and text != "" do
    case Magus.Files.EmbeddingModel.embed(text) do
      {:ok, embedding} ->
        {:ok, Pgvector.new(embedding)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_embedding(_), do: {:error, :no_content}
end
