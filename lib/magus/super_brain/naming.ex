defmodule Magus.SuperBrain.Naming do
  @moduledoc """
  Shared name-key normalization for claims. A key is the downcased,
  whitespace-collapsed, trimmed form of an entity name, used as `subject_key` /
  `object_key` and for grouping claims by entity. Defined once so every call
  site (extraction, retrieval, dossier, context, eval subjects) agrees.
  """

  @spec key(term()) :: String.t()
  def key(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  def key(_), do: ""
end
