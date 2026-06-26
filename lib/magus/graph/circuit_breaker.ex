defmodule Magus.Graph.CircuitBreaker do
  @moduledoc """
  Simple GenServer-backed circuit breaker.

  Supports a `disabled: true` option that turns the breaker into a no-op:
  `state/1` always returns `:closed` and `record_failure/1`/`record_success/1`
  are dropped. The flag is meant for the test environment, where ExUnit runs
  many graph-touching tests in parallel and transient FalkorDB errors from
  unrelated tests would otherwise sum into a global trip. The breaker is a
  production hot-loop safety net, not a test-isolation primitive.
  """
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def state(name), do: GenServer.call(name, :state)
  def record_failure(name), do: GenServer.cast(name, :failure)
  def record_success(name), do: GenServer.cast(name, :success)

  @impl true
  def init(opts) do
    state = %{
      threshold: Keyword.get(opts, :threshold, 5),
      reset_after: Keyword.get(opts, :reset_after, 30_000),
      disabled: Keyword.get(opts, :disabled, false),
      failures: 0,
      opened_at: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %{disabled: true} = state), do: {:reply, :closed, state}

  def handle_call(:state, _from, state) do
    {:reply, current_state(state), state}
  end

  @impl true
  def handle_cast(_msg, %{disabled: true} = state), do: {:noreply, state}

  def handle_cast(:failure, state) do
    state = %{state | failures: state.failures + 1}

    state =
      if state.failures >= state.threshold and is_nil(state.opened_at) do
        %{state | opened_at: System.monotonic_time(:millisecond)}
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast(:success, state) do
    {:noreply, %{state | failures: 0, opened_at: nil}}
  end

  defp current_state(%{opened_at: nil}), do: :closed

  defp current_state(%{opened_at: t, reset_after: r}) do
    if System.monotonic_time(:millisecond) - t >= r, do: :closed, else: :open
  end
end
