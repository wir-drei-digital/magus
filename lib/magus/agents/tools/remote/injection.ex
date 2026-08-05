defmodule Magus.Agents.Tools.Remote.Injection do
  @moduledoc """
  Appends per-turn local (reverse-tunnel) tool modules to an `ai.react.query`
  signal's `:tools` — WITHOUT replacing the agent's normal toolset. `run_tools`
  is per-turn in the strategy and cleared on completion, so this never leaks
  into other turns or into a hibernated/thawed agent.

  No routing identity is threaded here: reverse-tunnel tools resolve the
  caller's connection from the server-side `acting_user_id` that Preflight
  already puts into every tool context.
  """

  alias Magus.Agents.Tools.Remote.Catalog

  @spec augment(map(), map()) :: map()
  def augment(signal, data) when is_map(signal) and is_map(data) do
    existing = Map.get(signal, :tools)
    mods = Catalog.resolve(get(data, :local_tools) || [])

    # Append only onto a known, non-empty base toolset. `[]` means a non-tool
    # model (build_tools/3 yields [] for those) and nil means Preflight's
    # degraded context branch — in both cases appending would make read_file
    # the model's ENTIRE toolset, so both stay a hard no-op.
    if is_list(existing) and existing != [] and mods != [] do
      Map.put(signal, :tools, Enum.uniq(existing ++ mods))
    else
      signal
    end
  end

  defp get(data, key), do: Map.get(data, key) || Map.get(data, to_string(key))
end
