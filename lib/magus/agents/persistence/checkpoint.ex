defmodule Magus.Agents.Persistence.Checkpoint do
  @moduledoc """
  Shared helpers for agent checkpoint/restore operations.

  Provides canonical patterns for serializing and deserializing agent state
  during hibernation and recovery. Used by `ConversationAgent` and any future
  agents that persist to PostgreSQL via `PostgresStore`.
  """

  @doc """
  Get a value from a map using either an atom or string key.

  Checkpoint data may have atom keys (in-memory) or string keys (after JSON
  round-trip through the database). This helper checks both.

  ## Examples

      iex> get_value(%{user_id: "123"}, :user_id)
      "123"

      iex> get_value(%{"user_id" => "123"}, :user_id)
      "123"

      iex> get_value(%{}, :user_id)
      nil
  """
  def get_value(map, key) when is_atom(key) and is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  def get_value(_, _), do: nil

  @doc """
  Build the canonical checkpoint envelope for persistence.

  Returns `{:ok, checkpoint}` with the standard format expected by `Jido.Persist`.

  ## Parameters

    * `agent_module` — the agent module (e.g. `ConversationAgent`)
    * `agent_id` — the agent's string ID
    * `domain_state` — a map of domain-specific state to nest under `:state`

  ## Example

      iex> wrap_checkpoint(MyAgent, "conv:123", %{user_id: "u1"})
      {:ok, %{version: 1, agent_module: MyAgent, id: "conv:123", state: %{user_id: "u1"}}}
  """
  def wrap_checkpoint(agent_module, agent_id, domain_state) when is_map(domain_state) do
    {:ok,
     %{
       version: 1,
       agent_module: agent_module,
       id: agent_id,
       state: domain_state,
       thread: nil
     }}
  end

  @doc """
  Extract domain state from checkpoint data.

  Handles both the canonical format (state nested under `:state` key) and
  legacy flat format (state at top level). Returns the state map.
  """
  def extract_state(data) when is_map(data) do
    case get_value(data, :state) do
      s when is_map(s) and map_size(s) > 0 -> s
      _ -> data
    end
  end

  @doc """
  Validate that required fields are present and non-empty in the checkpoint data.

  Takes the checkpoint data map, the extracted state data map, and a list of
  `{source, field}` tuples where `source` is `:data` (top-level) or `:state`.

  Returns `:ok` or `{:error, {:missing_field, field_name}}`.

  ## Example

      iex> validate_required(%{"id" => "x"}, %{"user_id" => "u"}, [data: :id, state: :user_id])
      :ok

      iex> validate_required(%{}, %{"user_id" => "u"}, [data: :id, state: :user_id])
      {:error, {:missing_field, :id}}
  """
  def validate_required(data, state_data, fields) do
    Enum.reduce_while(fields, :ok, fn {source, field}, :ok ->
      map = if source == :data, do: data, else: state_data
      value = get_value(map, field)

      if is_nil(value) or value == "" do
        {:halt, {:error, {:missing_field, field}}}
      else
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Parse a datetime value that may be a `DateTime` struct, an ISO 8601 string, or nil.

  Returns a `DateTime` struct or nil.
  """
  def parse_datetime(nil), do: nil
  def parse_datetime(%DateTime{} = dt), do: dt

  def parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  def parse_datetime(_), do: nil
end
