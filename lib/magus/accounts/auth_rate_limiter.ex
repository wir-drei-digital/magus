defmodule Magus.Accounts.AuthRateLimiter do
  @moduledoc """
  Rate limits for unauthenticated auth endpoints (see the signup-abuse
  spec). Disabled unless `config :magus, :auth_rate_limits, enabled: true`.
  Scopes and `{limit, :minute | :hour}` pairs come from that config.
  """

  use GenServer

  alias Magus.RateLimiting.FixedWindow

  @table :auth_rate_limits
  @sweep_interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(scope, key) do
    config = Application.get_env(:magus, :auth_rate_limits, [])

    with true <- Keyword.get(config, :enabled, false),
         {limit, window} <- Keyword.get(config, scope) do
      FixedWindow.check(@table, scope, key, {limit, window_ms(window)})
    else
      _ -> :ok
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    FixedWindow.sweep(@table)
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
  defp window_ms(:minute), do: 60_000
  defp window_ms(:hour), do: 3_600_000
end
