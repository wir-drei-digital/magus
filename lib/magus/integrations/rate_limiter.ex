defmodule Magus.Integrations.RateLimiter do
  @moduledoc """
  ETS-based rate limiting per user/provider/operation.

  Provides sliding window rate limiting for integration operations.
  Each user has separate rate limits per provider and operation type.
  """

  use GenServer

  alias Magus.RateLimiting.FixedWindow

  @default_limits %{
    google_calendar: %{
      list_events: {100, :hour},
      create_event: {50, :hour},
      update_event: {50, :hour},
      delete_event: {50, :hour},
      list_calendars: {20, :hour}
    },
    telegram: %{
      send_message: {30, :minute},
      send_photo: {20, :minute},
      webhook: {100, :minute}
    },
    email: %{
      send: {10, :hour},
      fetch: {60, :hour}
    },
    simple_webhook: %{
      webhook: {200, :minute},
      send_message: {100, :minute}
    },
    google_drive_knowledge: %{sync: {100, :hour}},
    notion_knowledge: %{sync: {100, :hour}},
    nextcloud_knowledge: %{sync: {100, :hour}},
    affine_knowledge: %{sync: {100, :hour}}
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an operation is allowed under rate limits.

  Returns `:ok` if allowed, `{:error, :rate_limited}` if blocked.
  """
  @spec check(String.t(), atom(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, provider_key, operation) do
    {limit, window} = get_limit(provider_key, operation)
    window_ms = window_to_ms(window)

    FixedWindow.check(
      :integration_rate_limits,
      provider_key,
      {user_id, operation},
      {limit, window_ms}
    )
  end

  @doc """
  Get the current rate limit status for a user/provider/operation.

  Returns `{current_count, limit, window_ms_remaining}`.
  """
  @spec status(String.t(), atom(), atom()) ::
          {non_neg_integer(), pos_integer(), non_neg_integer()}
  def status(user_id, provider_key, operation) do
    key = {user_id, provider_key, operation}
    {limit, window} = get_limit(provider_key, operation)
    window_ms = window_to_ms(window)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(:integration_rate_limits, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        remaining = window_ms - (now - window_start)
        {count, limit, remaining}

      _ ->
        {0, limit, window_ms}
    end
  end

  @doc """
  Reset rate limits for a specific user/provider/operation.
  Useful for testing or admin overrides.
  """
  @spec reset(String.t(), atom(), atom()) :: :ok
  def reset(user_id, provider_key, operation) do
    key = {user_id, provider_key, operation}
    :ets.delete(:integration_rate_limits, key)
    :ok
  end

  # Server callbacks

  @impl GenServer
  def init(_opts) do
    # Public access required since check/3 writes directly to ETS for performance.
    # Rate limiting is not security-critical - modifying limits doesn't expose sensitive data.
    :ets.new(:integration_rate_limits, [:named_table, :public, :set, write_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    FixedWindow.sweep(:integration_rate_limits)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp get_limit(provider_key, operation) do
    @default_limits
    |> Map.get(provider_key, %{})
    |> Map.get(operation, {100, :hour})
  end

  defp window_to_ms(:second), do: 1_000
  defp window_to_ms(:minute), do: 60_000
  defp window_to_ms(:hour), do: 3_600_000
  defp window_to_ms(:day), do: 86_400_000

  defp schedule_cleanup do
    # Clean up expired entries every 5 minutes
    Process.send_after(self(), :cleanup, 5 * 60 * 1000)
  end
end
