defmodule Magus.Agents.Tools.Remote.Catalog do
  @moduledoc """
  The fixed, known set of local (reverse-tunnel) tools the cloud may propose.

  The capability set is finite and reviewed on both ends. Names that are not in
  the catalog are dropped — the server never invents a capability from the wire
  (zero-trust). New tool *kinds* require a deploy + a CLI release.
  """

  alias Magus.Agents.Tools.Remote.ReadFile

  @known %{"read_file" => ReadFile}

  @spec known() :: %{optional(String.t()) => module()}
  def known, do: @known

  @spec names() :: [String.t()]
  def names, do: Map.keys(@known)

  @spec known?(String.t()) :: boolean()
  def known?(name), do: Map.has_key?(@known, name)

  @spec resolve([String.t()]) :: [module()]
  def resolve(names) when is_list(names) do
    names |> Enum.map(&Map.get(@known, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  def resolve(_), do: []
end
