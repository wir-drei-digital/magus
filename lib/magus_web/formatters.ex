defmodule MagusWeb.Formatters do
  @moduledoc """
  Shared formatting helpers for display values across the application.
  """

  @doc """
  Formats a byte count into a human-readable string (e.g. "1.5 GB", "512 KB", "100 B").

  Handles nil, 0, string inputs (via Integer.parse), and the full range from bytes to GB.
  """
  def format_bytes(nil), do: "0 B"
  def format_bytes(0), do: "0 B"

  def format_bytes(n) when is_binary(n) do
    case Integer.parse(n) do
      {int, _} -> format_bytes(int)
      :error -> "0 B"
    end
  end

  def format_bytes(bytes) when is_number(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  def format_bytes(bytes) when is_number(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_bytes(bytes) when is_number(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_bytes(bytes) when is_number(bytes), do: "#{bytes} B"
  def format_bytes(_), do: "0 B"
end
