defmodule Magus.RateLimiting.FixedWindowTest do
  use ExUnit.Case, async: true

  alias Magus.RateLimiting.FixedWindow

  setup do
    table = :ets.new(:fw_test, [:set, :public])
    {:ok, table: table}
  end

  test "allows up to limit then rejects", %{table: table} do
    for _ <- 1..3, do: assert(:ok == FixedWindow.check(table, :s, "k", {3, 60_000}))
    assert {:error, :rate_limited} == FixedWindow.check(table, :s, "k", {3, 60_000})
  end

  test "keys are independent per scope and key", %{table: table} do
    assert :ok == FixedWindow.check(table, :a, "k", {1, 60_000})
    assert :ok == FixedWindow.check(table, :b, "k", {1, 60_000})
    assert :ok == FixedWindow.check(table, :a, "k2", {1, 60_000})
  end

  test "atomic under concurrency: exactly limit succeed", %{table: table} do
    results =
      1..50
      |> Task.async_stream(fn _ -> FixedWindow.check(table, :c, "k", {10, 60_000}) end,
        max_concurrency: 50
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 10
  end

  test "sweep deletes only expired buckets", %{table: table} do
    # a tiny window that has certainly passed, and a live one-hour window
    assert :ok == FixedWindow.check(table, :s, "old", {5, 1})
    Process.sleep(5)
    assert :ok == FixedWindow.check(table, :s, "new", {5, 3_600_000})
    assert FixedWindow.sweep(table) == 1
    assert :ets.info(table, :size) == 1
  end
end
