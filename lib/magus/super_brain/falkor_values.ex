defmodule Magus.SuperBrain.FalkorValues do
  @moduledoc """
  Decoders and helpers for values returned by FalkorDB through the
  Cypher driver.

  FalkorDB's verbose protocol serializes numeric properties and
  procedure-yielded scalars as strings; embeddings stored via
  `vecf32([...])` come back as the literal string
  `"<f1, f2, ...>"` rather than a list. These helpers normalize both
  shapes so callers can pattern-match on plain Elixir values without
  scattering the same defensive parsing across every worker.

  Pre-Wave-2 these helpers were copy/pasted into every worker
  (extract_base, build_super_full, build_super_incremental) with no
  shared definition. The copies had started to drift, so hoisting them
  here makes the contract explicit and gives a single edit point.
  """

  @doc """
  Coerce a FalkorDB-emitted numeric scalar to a float.

  Numbers pass through unchanged; numeric binaries are parsed; anything
  else returns the caller-supplied default.
  """
  @spec parse_number(any(), float()) :: float()
  def parse_number(nil, default), do: default
  def parse_number(n, _default) when is_number(n), do: n * 1.0

  def parse_number(s, default) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> default
    end
  end

  def parse_number(_other, default), do: default

  @doc """
  Parse a FalkorDB-stored embedding into a list of floats.

  Accepts the verbose-mode string form (`"<1.0, 2.0, ...>"`), a plain
  list (already-decoded driver shape), or nil/empty. Anything else
  returns `[]` so callers never need to defend against unexpected
  shapes inline.
  """
  @spec parse_embedding(any()) :: [float()]
  def parse_embedding(nil), do: []
  def parse_embedding([]), do: []
  def parse_embedding(list) when is_list(list), do: list

  def parse_embedding(s) when is_binary(s) do
    s
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case Float.parse(part) do
        {f, _} -> f
        :error -> 0.0
      end
    end)
  end

  def parse_embedding(_), do: []

  @doc """
  Cosine similarity between two equal-length vectors.

  Returns `0.0` when either vector is empty, lengths differ, or either
  norm is zero (avoiding a divide-by-zero crash on the all-zero
  fallback vector).
  """
  @spec cosine_similarity([number()], [number()]) :: float()
  def cosine_similarity([], _), do: 0.0
  def cosine_similarity(_, []), do: 0.0

  def cosine_similarity(a, b) when length(a) == length(b) do
    dot = a |> Enum.zip(b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    na = :math.sqrt(a |> Enum.map(&(&1 * &1)) |> Enum.sum())
    nb = :math.sqrt(b |> Enum.map(&(&1 * &1)) |> Enum.sum())
    if na == 0 or nb == 0, do: 0.0, else: dot / (na * nb)
  end

  def cosine_similarity(_, _), do: 0.0

  @doc """
  Modal element of the list, with a `"relates_to"` fallback when empty
  (matching the predicate aggregator's pre-Wave-2 default).

  Used by the RELATES_TO aggregators to pick the modal predicate
  across a group of source edges. Nils are filtered out so callers
  do not need to pre-clean.
  """
  @spec most_common([any()]) :: any()
  def most_common(list) do
    list
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> case do
      m when map_size(m) == 0 ->
        "relates_to"

      freq ->
        freq
        |> Enum.max_by(fn {_v, n} -> n end)
        |> elem(0)
    end
  end
end
