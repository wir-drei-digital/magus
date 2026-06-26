defmodule Magus.Cache do
  @moduledoc """
  Simple ETS-based cache with TTL support.

  Used for rate limiting and short-lived cached values.
  For production at scale, consider using Cachex or similar.

  ## Usage

      # Store a value with default TTL (1 hour)
      Magus.Cache.put("my_key", "my_value")

      # Store a value with custom TTL (in seconds)
      Magus.Cache.put("my_key", "my_value", ttl: 300)

      # Retrieve a value
      Magus.Cache.get("my_key")  # Returns value or nil

      # Delete a value
      Magus.Cache.delete("my_key")
  """

  use GenServer

  @table_name :magus_cache
  @cleanup_interval :timer.minutes(5)

  # Client API

  @doc """
  Starts the cache server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a value from the cache.

  Returns the value if found and not expired, `nil` otherwise.
  """
  @spec get(term()) :: term() | nil
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          value
        else
          delete(key)
          nil
        end

      [] ->
        nil
    end
  rescue
    # Handle case where table doesn't exist yet (during startup)
    ArgumentError -> nil
  end

  @doc """
  Puts a value in the cache.

  ## Options

    * `:ttl` - Time to live in seconds. Defaults to 3600 (1 hour).
  """
  @spec put(term(), term(), keyword()) :: :ok
  def put(key, value, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, 3600)
    expires_at = DateTime.add(DateTime.utc_now(), ttl, :second)
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    # Handle case where table doesn't exist yet (during startup)
    ArgumentError -> :ok
  end

  @doc """
  Deletes a value from the cache.
  """
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table_name, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Checks if a key exists in the cache and is not expired.

  Note: This function cannot distinguish between a non-existent key and
  a key with a nil value. If you need to store nil values and check existence,
  use `get/1` and pattern match on the result, or use a sentinel value.
  """
  @spec exists?(term()) :: boolean()
  def exists?(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, _value, expires_at}] ->
        DateTime.compare(DateTime.utc_now(), expires_at) == :lt

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:set, :public, :named_table])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired_entries do
    now = DateTime.utc_now()

    # For simplicity and maintainability, we use foldl to iterate and delete
    # expired entries. For high-volume caches, consider switching to a simpler
    # expiration format (Unix timestamps) to enable efficient :ets.select_delete.
    @table_name
    |> :ets.tab2list()
    |> Enum.each(fn {key, _value, expires_at} ->
      if DateTime.compare(now, expires_at) != :lt do
        :ets.delete(@table_name, key)
      end
    end)
  rescue
    ArgumentError -> nil
  end
end
