defmodule Magus.Models.RateWindow do
  @moduledoc """
  Tiny per-key rate window backed by a public ETS table. Returns true when
  the key has not fired inside the window and records the hit. Best-effort
  (per-node, resets on restart), which is sufficient for bounding live
  credential probes triggered from the UI.
  """

  @table __MODULE__

  @spec allow?(term(), pos_integer()) :: boolean()
  def allow?(key, window_ms) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, last}] when now - last < window_ms ->
        false

      _ ->
        :ets.insert(@table, {key, now})
        true
    end
  end

  defp ensure_table do
    :ets.whereis(@table) != :undefined ||
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
  rescue
    ArgumentError -> :ok
  end
end
