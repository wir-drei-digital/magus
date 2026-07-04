defmodule Magus.SuperBrain.Naming do
  @moduledoc """
  Shared name-key normalization for the claim layer. A key is the downcased,
  whitespace-collapsed, trimmed form of an entity name, used as `subject_key` /
  `object_key` and for grouping claims by entity. Every claim-layer call site
  (extraction, retrieval, dossier, context, eval subjects) uses this one
  function so the keys agree.

  Distinct from `Magus.SuperBrain.CanonicalId.name_key/1`, which keys entity
  names for FalkorDB canonical-entity bucketing: that one downcases and trims
  but does NOT collapse internal whitespace and folds blank names to a
  `__noname__` sentinel. The two layers are intentionally not unified, since
  changing the canonical bucket key would alter entity fusion in the graph,
  which is out of scope for the claim work.
  """

  @spec key(term()) :: String.t()
  def key(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  def key(_), do: ""
end
