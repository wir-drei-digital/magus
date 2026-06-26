defmodule Magus.Agents.Persistence.PostgresStore do
  @moduledoc """
  PostgreSQL-backed storage adapter implementing the Jido.Storage behaviour.

  Persists agent checkpoints using the AgentState Ash resource, enabling agent
  hibernation and recovery across process boundaries.

  ## Key Serialization

  The InstanceManager creates composite persistence keys like
  `{:conversations, "conv:uuid"}`. The pool name is redundant since the
  `agent_module` column already disambiguates agents, so we strip it and
  store just the agent ID string (e.g. `"conv:uuid"`).

  ## Thread Operations

  Thread operations return stubs (`:not_found` / `:ok`) since conversation
  history is managed by the Chat domain, not the Jido agent journal.
  The agents don't use `__thread__` in state, so `flush_journal` in
  `Jido.Persist` always short-circuits to `:ok`.
  """

  require Logger
  require Ash.Query

  @behaviour Jido.Storage

  @impl true
  def get_checkpoint(key, _opts) do
    {module, agent_id} = key
    module_name = serialize_module(module)
    agent_id_str = serialize_key(agent_id)

    Logger.info(
      "PostgresStore.get_checkpoint: Looking up agent #{agent_id_str} (module: #{module_name})"
    )

    case Magus.Agents.AgentState
         |> Ash.Query.filter(agent_module == ^module_name and agent_id == ^agent_id_str)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Logger.info("PostgresStore.get_checkpoint: No persisted state found for #{agent_id_str}")
        :not_found

      {:ok, state_record} ->
        Logger.info("PostgresStore.get_checkpoint: Found persisted state for #{agent_id_str}")

        # Atomize top-level keys so Jido.Persist can pattern match on :thread, :state, etc.
        {:ok, atomize_top_level_keys(state_record.state_data)}

      {:error, error} ->
        Logger.error(
          "PostgresStore.get_checkpoint: Failed to load agent state: #{inspect(error)}"
        )

        {:error, error}
    end
  end

  @impl true
  def put_checkpoint(key, data, _opts) do
    {module, agent_id} = key

    case Magus.Agents.AgentState
         |> Ash.Changeset.for_create(:upsert, %{
           agent_module: serialize_module(module),
           agent_id: serialize_key(agent_id),
           state_data: sanitize_for_json(data),
           version: 1
         })
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to save agent state: #{inspect(error)}")
        {:error, error}
    end
  end

  @impl true
  def delete_checkpoint(key, _opts) do
    {module, agent_id} = key
    module_name = serialize_module(module)
    agent_id_str = serialize_key(agent_id)

    case Magus.Agents.AgentState
         |> Ash.Query.filter(agent_module == ^module_name and agent_id == ^agent_id_str)
         |> Ash.Query.select([:id])
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        :ok

      {:ok, state_record} ->
        case Ash.destroy(state_record, authorize?: false) do
          :ok ->
            :ok

          {:error, error} ->
            Logger.error("Failed to delete agent state: #{inspect(error)}")
            {:error, error}
        end

      {:error, error} ->
        Logger.error("Failed to query agent state for deletion: #{inspect(error)}")
        {:error, error}
    end
  end

  # Thread operations are not supported - conversation history is managed
  # by the Chat domain, not the Jido agent journal. These stubs satisfy
  # the Jido.Storage behaviour. They are never called in practice because
  # agents don't use __thread__ in state, so flush_journal short-circuits.

  @impl true
  def load_thread(_thread_id, _opts), do: :not_found

  @impl true
  def append_thread(_thread_id, _entries, _opts), do: {:error, :not_supported}

  @impl true
  def delete_thread(_thread_id, _opts), do: :ok

  # Private helpers

  # Recursively strip non-JSON-serializable values (PIDs, refs, ports, functions,
  # structs without Jason.Encoder) from checkpoint data to prevent errors during hibernation.
  defp sanitize_for_json(%_{} = struct) do
    struct |> Map.from_struct() |> sanitize_for_json()
  end

  defp sanitize_for_json(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(data) when is_list(data) do
    if Keyword.keyword?(data) do
      data |> Map.new() |> sanitize_for_json()
    else
      Enum.map(data, &sanitize_for_json/1)
    end
  end

  defp sanitize_for_json(data) when is_tuple(data) do
    data |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(data) when is_pid(data), do: nil
  defp sanitize_for_json(data) when is_reference(data), do: nil
  defp sanitize_for_json(data) when is_port(data), do: nil
  defp sanitize_for_json(data) when is_function(data), do: nil
  defp sanitize_for_json(data), do: data

  # Serialize the checkpoint key to a string for DB storage.
  # The InstanceManager creates composite keys like {:conversations, "conv:uuid"}.
  # The pool name is redundant (agent_module disambiguates), so we strip it.
  defp serialize_key(key) when is_binary(key), do: key
  defp serialize_key({_pool_name, id}) when is_binary(id), do: id
  defp serialize_key(key), do: inspect(key)

  defp serialize_module(module) when is_atom(module), do: inspect(module)
  defp serialize_module(name) when is_binary(name), do: name

  # Known top-level checkpoint keys that Jido.Persist pattern matches on.
  # Only these string keys are atomized; unknown keys pass through as strings.
  @checkpoint_keys Map.new(
                     ~w(version id state thread agent_module)a,
                     &{Atom.to_string(&1), &1}
                   )

  # Atomize top-level string keys from JSON deserialization so Jido.Persist
  # can pattern match on atom keys like :thread, :state, :id, etc.
  # Also ensures :thread key exists (defaults to nil) so rehydrate_thread/4 can match.
  defp atomize_top_level_keys(data) when is_map(data) do
    data
    |> Map.new(fn
      {key, value} when is_binary(key) ->
        {Map.get(@checkpoint_keys, key, key), value}

      pair ->
        pair
    end)
    |> Map.put_new(:thread, nil)
  end
end
