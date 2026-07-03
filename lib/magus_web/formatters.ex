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

  @doc """
  Formats an integer with thousands separators (e.g. `1234567` -> "1,234,567").

  Decimals are accepted for whole-number aggregates (SQL `SUM` over bigint
  returns numeric); anything else falls back to `to_string/1`.
  """
  def format_number(num) when is_integer(num) do
    num
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_number(%Decimal{} = num), do: format_number(Decimal.to_integer(Decimal.round(num)))
  def format_number(num), do: to_string(num)

  @doc """
  Formats a Decimal cost as a dollar amount, e.g. "$1.2345". `decimals`
  controls rounding (default 4 — sub-cent LLM costs); nil renders as $0.
  """
  def format_cost(cost, decimals \\ 4)
  def format_cost(nil, decimals), do: format_cost(Decimal.new(0), decimals)

  def format_cost(%Decimal{} = cost, decimals) do
    "$" <> (cost |> Decimal.round(decimals) |> Decimal.to_string())
  end
end
