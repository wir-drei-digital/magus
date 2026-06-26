defmodule Magus.Files.File.Calculations.LlmContentPart do
  @moduledoc """
  Calculates the LLM-compatible content part for a file.

  Returns a map suitable for inclusion in LLM messages:
  - Images: `%{type: :image, media_type: "image/png", data: "base64..."}`
  - Documents: `%{type: :text, text: "<attachment>...</attachment>"}`
  """
  use Ash.Resource.Calculation

  require Logger

  alias Magus.Files.{Extractor, FileAnalyzer, Storage}

  # Anthropic rejects base64 images >5MB. Base64 encoding inflates raw bytes by
  # ~4/3, so anything above ~3.75MB raw will exceed the limit. We keep a safety
  # margin and cap raw bytes at 3.5MB.
  @max_image_bytes 3_500_000

  @impl true
  def load(_query, _opts, _context), do: [:type, :name, :mime_type, :file_path, :file_size]

  @impl true
  def calculate(files, _opts, _context) do
    Enum.map(files, &build_content_part/1)
  end

  defp build_content_part(%{type: :image} = file) do
    case Storage.get(file.file_path) do
      {:ok, content} when is_binary(content) ->
        if byte_size(content) > @max_image_bytes do
          %{
            type: :text,
            text:
              "<attachment filename=\"#{file.name}\">[Image omitted: " <>
                "#{format_mb(byte_size(content))} exceeds the " <>
                "#{format_mb(@max_image_bytes)} per-image limit. " <>
                "Resize or compress the image before attaching.]</attachment>"
          }
        else
          %{type: :image, media_type: file.mime_type, data: Base.encode64(content)}
        end

      {:error, reason} ->
        Logger.warning("Failed to load image #{file.file_path}: #{inspect(reason)}")
        nil
    end
  end

  defp build_content_part(%{type: type} = file) when type in [:document, :text, :email] do
    case Storage.get(file.file_path) do
      {:ok, content} when is_binary(content) ->
        extracted = extract_text(content, type, file.name)

        %{
          type: :text,
          text: "<attachment filename=\"#{file.name}\">\n#{extracted}\n</attachment>"
        }

      {:error, reason} ->
        Logger.warning("Failed to load file #{file.file_path}: #{inspect(reason)}")
        nil
    end
  end

  defp build_content_part(%{type: :video} = file) do
    %{
      type: :text,
      text: "<attachment filename=\"#{file.name}\">[Video content]</attachment>"
    }
  end

  defp build_content_part(file) do
    Logger.warning("Unknown file type: #{inspect(file.type)}")
    nil
  end

  defp extract_text(content, :text, name) do
    case FileAnalyzer.to_utf8(content) do
      {:ok, text} -> text
      {:error, :binary} -> "[Text file: #{name} - non-UTF-8 content could not be decoded]"
    end
  end

  defp extract_text(content, type, name) when type in [:document, :email] do
    case Extractor.extract_from_content(content, type) do
      {:ok, text} when byte_size(text) > 0 -> text
      {:ok, _} -> "[Document: #{name} - no text content extracted]"
      {:error, _} -> "[Document: #{name} - content extraction failed]"
    end
  end

  defp format_mb(bytes) do
    :erlang.float_to_binary(bytes / 1_000_000, decimals: 1) <> " MB"
  end
end
