defmodule Magus.Agents.Plugins.Support.RunRelay do
  @moduledoc """
  Shared helper for relaying child conversation events to a parent conversation's
  spawn_sub_agent tool card.

  Used by both `ToolEventPlugin` (tool events) and `StreamingPlugin` (text streaming)
  to look up the parent conversation and source_event_id for cross-conversation relay.

  Caches the lookup result in the Process dictionary to avoid repeated DB queries
  per streaming delta. Cache is keyed by child conversation_id.
  """

  require Logger

  @cache_key :run_relay_cache

  @doc """
  Look up the parent conversation and source_event_id for a child conversation.

  Returns `{source_conversation_id, source_event_id}` or `nil` if no active run
  with a source_event_id is found (e.g., the conversation is not a sub-agent).

  Results are cached in the Process dictionary per child_conversation_id.
  """
  @spec find_parent(String.t()) :: {String.t(), String.t()} | nil
  def find_parent(child_conversation_id) do
    cache = Process.get(@cache_key) || %{}

    case Map.fetch(cache, child_conversation_id) do
      {:ok, result} ->
        result

      :error ->
        result = do_find_parent(child_conversation_id)
        Process.put(@cache_key, Map.put(cache, child_conversation_id, result))
        result
    end
  end

  @doc """
  Clear the cached parent lookup for a child conversation.

  Call this when a turn completes to allow re-lookup on the next turn
  (in case the run completed between turns).
  """
  @spec clear_cache(String.t()) :: :ok
  def clear_cache(child_conversation_id) do
    cache = Process.get(@cache_key) || %{}
    Process.put(@cache_key, Map.delete(cache, child_conversation_id))
    :ok
  end

  @doc """
  Clear the entire relay cache.
  """
  @spec clear_all_cache() :: :ok
  def clear_all_cache do
    Process.delete(@cache_key)
    :ok
  end

  defp do_find_parent(child_conversation_id) do
    case Magus.Agents.running_agent_runs_by_target(child_conversation_id, authorize?: false) do
      {:ok, [run | _]} when not is_nil(run.source_event_id) ->
        {to_string(run.source_conversation_id), run.source_event_id}

      {:ok, _} ->
        nil

      {:error, _} ->
        nil
    end
  rescue
    e ->
      Logger.warning("RunRelay: parent lookup failed: #{Exception.message(e)}")
      nil
  end
end
