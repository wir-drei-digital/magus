defmodule Magus.Graph.CircuitBreakerTest do
  use ExUnit.Case, async: false
  alias Magus.Graph.CircuitBreaker

  setup do
    {:ok, _} = start_supervised({CircuitBreaker, name: :cb_test, threshold: 3, reset_after: 100})
    :ok
  end

  test "closed → open after threshold consecutive failures" do
    assert :closed = CircuitBreaker.state(:cb_test)
    for _ <- 1..3, do: CircuitBreaker.record_failure(:cb_test)
    assert :open = CircuitBreaker.state(:cb_test)
  end

  test "open → closed after reset_after ms" do
    for _ <- 1..3, do: CircuitBreaker.record_failure(:cb_test)
    assert :open = CircuitBreaker.state(:cb_test)
    Process.sleep(150)
    assert :closed = CircuitBreaker.state(:cb_test)
  end

  test "successful call resets failure counter" do
    CircuitBreaker.record_failure(:cb_test)
    CircuitBreaker.record_success(:cb_test)
    CircuitBreaker.record_failure(:cb_test)
    CircuitBreaker.record_failure(:cb_test)
    assert :closed = CircuitBreaker.state(:cb_test)
  end

  test "disabled: true reports :closed regardless of failure count" do
    {:ok, _} =
      start_supervised(
        Supervisor.child_spec(
          {CircuitBreaker, name: :cb_disabled, threshold: 2, reset_after: 100, disabled: true},
          id: :cb_disabled
        )
      )

    for _ <- 1..50, do: CircuitBreaker.record_failure(:cb_disabled)
    assert :closed = CircuitBreaker.state(:cb_disabled)
  end
end
