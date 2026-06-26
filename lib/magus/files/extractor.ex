defmodule Magus.Files.Extractor do
  @moduledoc """
  Extracts text content from different document types.

  Uses Kreuzberg (Rust NIF) for document extraction, providing high-performance
  text extraction from 75+ file formats with optional OCR support.

  Supports:
  - PDF documents
  - Microsoft Office files (docx, xlsx, pptx, doc, xls, ppt)
  - OpenDocument files (odt, ods, odp)
  - E-books (epub)
  - Email files (eml, msg)
  - Plain text and HTML/XML
  - Images (with OCR when Tesseract is available)
  """

  require Logger

  @doc """
  Extracts text from a document based on its type.
  Returns {:ok, text} or {:error, reason}
  """
  def extract(file_path, type) do
    case type do
      :document -> extract_document(file_path)
      :email -> extract_document(file_path)
      :text -> extract_text(file_path)
      :image -> extract_image(file_path)
      :video -> {:ok, "[Video content]"}
    end
  end

  @doc """
  Extracts text from raw content bytes based on type.
  Useful for extracting text from in-memory file data.

  Returns {:ok, text} or {:error, reason}
  """
  def extract_from_content(content, type) when is_binary(content) do
    case type do
      :document -> extract_document_from_bytes(content)
      :email -> extract_document_from_bytes(content)
      :text -> {:ok, content |> String.trim() |> clean_text()}
      :image -> {:ok, "[Image content]"}
      :video -> {:ok, "[Video content]"}
    end
  end

  @doc """
  Extracts text from raw content bytes with a known MIME type.

  Returns {:ok, text} or {:error, reason}
  """
  def extract_from_content(content, type, mime_type) when is_binary(content) do
    case type do
      :document -> extract_document_from_bytes(content, mime_type)
      :email -> extract_document_from_bytes(content, mime_type)
      :text -> {:ok, content |> String.trim() |> clean_text()}
      :image -> {:ok, "[Image content]"}
      :video -> {:ok, "[Video content]"}
    end
  end

  defp extract_document(file_path) do
    case Kreuzberg.extract_file(file_path) do
      {:ok, result} ->
        {:ok, result.content |> String.trim() |> clean_text()}

      {:error, reason} ->
        Logger.error("Document extraction failed for #{file_path}: #{inspect(reason)}")
        {:error, "Document extraction failed: #{String.slice(to_string(reason), 0, 200)}"}
    end
  rescue
    e ->
      Logger.error("Document extraction failed for #{file_path}: #{inspect(e)}")
      {:error, "Document extraction failed: #{inspect(e) |> String.slice(0, 200)}"}
  end

  defp extract_document_from_bytes(content, mime_type \\ nil) when is_binary(content) do
    mime = mime_type || detect_mime_type(content)

    case Kreuzberg.extract(content, mime) do
      {:ok, result} ->
        {:ok, result.content |> String.trim() |> clean_text()}

      {:error, reason} ->
        Logger.error("Document extraction from bytes failed: #{inspect(reason)}")
        {:error, "Document extraction failed: #{String.slice(to_string(reason), 0, 200)}"}
    end
  rescue
    e ->
      Logger.error("Document extraction from bytes failed: #{inspect(e)}")
      {:error, "Document extraction failed: #{inspect(e) |> String.slice(0, 200)}"}
  end

  defp extract_text(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        cleaned = content |> String.trim() |> clean_text()
        {:ok, cleaned}

      {:error, reason} ->
        {:error, "Failed to read text file: #{reason}"}
    end
  end

  defp extract_image(file_path) do
    filename = Path.basename(file_path)
    {:ok, "[Image: #{filename}]"}
  end

  defp detect_mime_type(content) do
    case Kreuzberg.detect_mime_type(content) do
      {:ok, mime} -> mime
      {:error, _} -> "application/octet-stream"
    end
  end

  defp clean_text(text) do
    text
    # Normalize line endings
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    # Remove excessive whitespace but preserve paragraph structure
    |> String.replace(~r/[ \t]+/, " ")
    # Remove excessive newlines (more than 2 in a row)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
