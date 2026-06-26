defmodule Magus.Eval.Subject do
  @moduledoc "The benchmark-agnostic boundary to a running Magus brain."

  @callback reset(ctx :: map) :: {:ok, map} | {:error, term}
  @callback ingest(ctx :: map, items :: [%{role: atom, text: String.t()}]) ::
              {:ok, map} | {:error, term}
  @callback query(ctx :: map, question :: String.t()) ::
              {:ok, %{answer: String.t(), meta: map}} | {:error, term}
end
