defmodule Magus.Files.Types.Vector do
  @moduledoc """
  Custom Ash type for pgvector embeddings.
  Stores vectors as pgvector type and casts to/from Elixir lists.
  """

  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :vector

  @impl true
  def cast_input(nil, _), do: {:ok, nil}
  def cast_input(%Pgvector{} = vector, _), do: {:ok, Pgvector.to_list(vector)}
  def cast_input(value, _) when is_list(value), do: {:ok, value}
  def cast_input(_, _), do: :error

  @impl true
  def cast_stored(nil, _), do: {:ok, nil}
  def cast_stored(%Pgvector{} = vector, _), do: {:ok, Pgvector.to_list(vector)}
  def cast_stored(value, _) when is_list(value), do: {:ok, value}
  def cast_stored(_, _), do: :error

  @impl true
  def dump_to_native(nil, _), do: {:ok, nil}
  def dump_to_native(value, _) when is_list(value), do: {:ok, Pgvector.new(value)}
  def dump_to_native(%Pgvector{} = vector, _), do: {:ok, vector}
  def dump_to_native(_, _), do: :error
end
