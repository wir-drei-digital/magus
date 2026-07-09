defmodule Magus.Files.File.Changes.ProcessFile do
  @moduledoc """
  Processes an uploaded file: extracts text, chunks it, generates embeddings,
  and creates chunk records.
  """

  use Ash.Resource.Change
  require Ash.Query
  require Logger

  alias Magus.Files.{Storage, Extractor, Chunker, EmbeddingModel, FileAnalyzer}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      file = changeset.data

      Logger.info("Processing file #{file.id}: #{file.name}")

      # Update status to processing
      update_status(file, :processing)

      result =
        with {:ok, content} <- get_file_content(file),
             {:ok, text} <- extract_text(file, content),
             {:ok, chunks} <- chunk_text(text),
             {:ok, _} <- create_chunks_with_embeddings(file, chunks) do
          # Update file to ready
          update_status(file, :ready, %{chunk_count: length(chunks)})

          Logger.info("Successfully processed file #{file.id} with #{length(chunks)} chunks")

          {:ok, changeset}
        end

      case result do
        {:ok, changeset} ->
          changeset

        {:error, reason} ->
          error_message = format_error(reason)
          Logger.error("File processing failed for #{file.id}: #{error_message}")
          update_status(file, :error, %{error_message: error_message})
          # Return the changeset without adding an error so the Oban job
          # succeeds and doesn't retry. The file status is already set to :error.
          changeset
      end
    end)
  end

  defp get_file_content(file) do
    Storage.get(file.file_path)
  end

  defp extract_text(file, content) do
    case file.type do
      :text ->
        case FileAnalyzer.to_utf8(content) do
          {:ok, text} -> {:ok, text}
          {:error, :binary} -> {:error, "Text file encoding is not supported"}
        end

      type when type in [:document, :email] ->
        Extractor.extract_from_content(content, type, file.mime_type)

      :image ->
        Extractor.extract(file.file_path, :image)

      :video ->
        {:ok, "[Video content]"}
    end
  end

  defp chunk_text(text) do
    text = String.trim(text)

    if text == "" do
      {:error, "Document is empty or contains no extractable text"}
    else
      chunks = Chunker.chunk_text(text)

      if Enum.empty?(chunks) do
        {:error, "Failed to create any chunks from document"}
      else
        {:ok, chunks}
      end
    end
  end

  defp create_chunks_with_embeddings(file, chunks) do
    # Extract text content for embedding
    texts = Enum.map(chunks, & &1.content)

    case EmbeddingModel.embed(texts) do
      {:ok, embeddings} ->
        # Replace prior chunks: reprocessing (connector updates set the file
        # back to :pending) must not leave stale rows behind. Old chunks stay
        # searchable until this point so a failed embed keeps the previous
        # generation intact.
        Magus.Files.Chunk
        |> Ash.Query.filter(file_id == ^file.id)
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: :atomic)

        # Create chunks with embeddings
        chunks
        |> Enum.zip(embeddings)
        |> Enum.each(fn {chunk, embedding} ->
          Magus.Files.create_chunk!(
            %{
              file_id: file.id,
              content: chunk.content,
              position: chunk.position,
              token_count: chunk.token_count,
              embedding: embedding,
              metadata: %{}
            },
            authorize?: false
          )
        end)

        {:ok, :created}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_status(file, status, extra_attrs \\ %{}) do
    attrs = Map.merge(%{status: status}, extra_attrs)

    Magus.Files.update_file_status!(
      file,
      attrs,
      authorize?: false
    )
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
