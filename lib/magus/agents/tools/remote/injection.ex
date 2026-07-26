defmodule Magus.Agents.Tools.Remote.Injection do
  @moduledoc """
  Augments an `ai.react.query` signal map with per-turn local tools and the
  caller's connection identity — WITHOUT replacing the agent's normal toolset.

  Appends resolved local-tool modules to `:tools` (uniq) and merges
  `caller_session_id` into `:tool_context`. Both `run_tools` and
  `run_tool_context` are per-turn in the strategy and cleared on completion, so
  this never leaks into other turns or into a hibernated/thawed agent.
  """

  alias Magus.Agents.Tools.Remote.Catalog

  @spec augment(map(), map()) :: map()
  def augment(signal, data) when is_map(signal) and is_map(data) do
    signal
    |> append_local_tools(get(data, :local_tools) || [])
    |> merge_caller_session(get(data, :caller_session_id))
  end

  defp append_local_tools(signal, names) do
    case {Map.get(signal, :tools), Catalog.resolve(names)} do
      # Append only when something resolved AND the base :tools is not an
      # explicit empty list. A non-tool model yields `[]` from build_tools/3
      # (Preflight always sets :tools, to [] for such models), so appending to
      # `[]` would make [ReadFile] the *entire* toolset for a model that cannot
      # use tools — hence the `existing != []` guard keeps that a hard no-op.
      # An ABSENT base (nil, "none existed yet") still sets tools; `List.wrap`
      # turns that nil into `[]` before the concat.
      {existing, mods} when existing != [] and mods != [] ->
        Map.put(signal, :tools, Enum.uniq(List.wrap(existing) ++ mods))

      {_existing, _mods} ->
        signal
    end
  end

  defp merge_caller_session(signal, nil), do: signal

  defp merge_caller_session(signal, sid) do
    Map.update(signal, :tool_context, %{caller_session_id: sid}, fn ctx ->
      Map.put(ctx || %{}, :caller_session_id, sid)
    end)
  end

  defp get(data, key), do: Map.get(data, key) || Map.get(data, to_string(key))
end
