defmodule Magus.Brain.Changes.GenerateChunkEmbedding do
  @moduledoc """
  Shared change for `Magus.Brain.PageChunk` and `Magus.Brain.SourceChunk`.
  Generates the embedding for the chunk's `:content` via
  `Magus.Files.EmbeddingModel` and writes it into the `:embedding`
  attribute.

  Skips when the content is too short (< 10 chars) so we don't waste a
  paid API call on a one-character chunk; the embedding stays `nil` and
  the next trigger tick re-evaluates. Logs on provider failures and
  leaves embedding `nil` so the trigger retries.
  """

  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      content = changeset.data.content

      if is_binary(content) and String.length(content) > 10 do
        # `embed/1` on a binary returns `{:ok, vector}` where `vector` is a
        # single list of floats (not a list of embeddings). Match it directly
        # — destructuring `[embedding | _]` would bind the first float and
        # `Vector.cast_input/2` rejects a bare float.
        case Magus.Files.EmbeddingModel.embed(content) do
          {:ok, embedding} when is_list(embedding) ->
            Ash.Changeset.force_change_attribute(changeset, :embedding, embedding)

          {:error, reason} ->
            Logger.warning(
              "GenerateChunkEmbedding: provider error on #{inspect(changeset.data.id)}: #{inspect(reason)}"
            )

            changeset
        end
      else
        changeset
      end
    end)
  end
end
