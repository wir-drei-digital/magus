defmodule Magus.Files.FileAnalyzer do
  @moduledoc """
  Detects whether binary content is text and normalizes it to UTF-8.

  Uses BOM-aware encoding detection plus a null-byte heuristic:
  - UTF-8/UTF-16 BOMs are treated as text
  - UTF-16 content is decoded to UTF-8
  - UTF-8 text without BOM is accepted
  - Latin-1 text without BOM is decoded to UTF-8 when bytes look text-like
  """

  @chunk_size 1024
  @latin1_text_threshold 0.9
  @latin1_c1_max_ratio 0.05

  @doc """
  Returns true if the binary content looks like a text file.
  """
  @spec text?(binary()) :: boolean()
  def text?(content) when is_binary(content) do
    match?({:ok, _text}, to_utf8(content))
  end

  @doc """
  Converts text-like binary data to UTF-8.

  Returns `{:ok, utf8_text}` when the content can be safely interpreted as text,
  otherwise `{:error, :binary}`.
  """
  @spec to_utf8(binary()) :: {:ok, String.t()} | {:error, :binary}
  def to_utf8(<<>>), do: {:ok, ""}

  # UTF-8 BOM
  def to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
    if String.valid?(rest), do: {:ok, rest}, else: {:error, :binary}
  end

  # UTF-16 LE BOM
  def to_utf8(<<0xFF, 0xFE, rest::binary>>), do: decode_utf16(rest, :little)

  # UTF-16 BE BOM
  def to_utf8(<<0xFE, 0xFF, rest::binary>>), do: decode_utf16(rest, :big)

  def to_utf8(content) when is_binary(content) do
    chunk = binary_part(content, 0, min(byte_size(content), @chunk_size))

    cond do
      :binary.match(chunk, <<0>>) != :nomatch ->
        {:error, :binary}

      String.valid?(content) ->
        {:ok, content}

      latin1_likely_text?(chunk) ->
        {:ok, :unicode.characters_to_binary(content, :latin1, :utf8)}

      true ->
        {:error, :binary}
    end
  end

  defp decode_utf16(content, endianness) do
    case :unicode.characters_to_binary(content, {:utf16, endianness}, :utf8) do
      decoded when is_binary(decoded) -> {:ok, decoded}
      _ -> {:error, :binary}
    end
  end

  defp latin1_likely_text?(<<>>), do: true

  defp latin1_likely_text?(chunk) do
    bytes = :binary.bin_to_list(chunk)
    total = length(bytes)

    {text_like_count, c1_count} =
      Enum.reduce(bytes, {0, 0}, fn byte, {text_like, c1} ->
        cond do
          byte in [9, 10, 13] ->
            {text_like + 1, c1}

          byte in 0x20..0x7E ->
            {text_like + 1, c1}

          byte in 0xA0..0xFF ->
            {text_like + 1, c1}

          byte in 0x80..0x9F ->
            {text_like, c1 + 1}

          true ->
            {text_like, c1}
        end
      end)

    text_like_ratio = text_like_count / total
    c1_ratio = c1_count / total

    text_like_ratio >= @latin1_text_threshold and c1_ratio <= @latin1_c1_max_ratio
  end
end
