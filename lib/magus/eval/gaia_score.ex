defmodule Magus.Eval.GaiaScore do
  @moduledoc """
  Deterministic quasi-exact-match scoring ported from GAIA's question_scorer:
  numbers compared as floats (units/commas/currency stripped), strings
  normalized (case, articles, punctuation, whitespace), comma-lists compared
  element-wise.
  """

  def match?(answer, gold) when is_binary(answer) and is_binary(gold) do
    cond do
      number?(gold) -> number_match?(answer, gold)
      String.contains?(gold, ",") -> list_match?(answer, gold)
      true -> norm_str(answer) == norm_str(gold)
    end
  end

  def match?(_, _), do: false

  defp number?(s), do: numeric_string?(normalize_number_string(s))
  defp numeric_string?(s), do: Regex.match?(~r/^-?\d+(\.\d+)?$/, s)

  defp number_match?(answer, gold) do
    with {a, _} <- Float.parse(normalize_number_string(answer)),
         {g, _} <- Float.parse(normalize_number_string(gold)) do
      abs(a - g) < 1.0e-6
    else
      _ -> false
    end
  end

  defp list_match?(answer, gold) do
    a = answer |> String.split(",") |> Enum.map(&norm_element/1)
    g = gold |> String.split(",") |> Enum.map(&norm_element/1)
    a == g
  end

  defp norm_element(s) do
    s = String.trim(s)
    if number?(s), do: normalize_number_string(s), else: norm_str(s)
  end

  defp normalize_number_string(s) do
    s
    |> String.replace(["$", "%", ","], "")
    |> String.trim()
  end

  defp norm_str(s) do
    s
    |> String.downcase()
    |> String.replace(~r/\b(a|an|the)\b/u, " ")
    |> String.replace(~r/[^\p{L}\p{N} ]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
