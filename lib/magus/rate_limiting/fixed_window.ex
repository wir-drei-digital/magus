defmodule Magus.RateLimiting.FixedWindow do
  @moduledoc """
  Atomic fixed-window counters on ETS.

  Key layout: `{scope, key, window_ms, bucket_index}` with
  `bucket_index = div(now_ms, window_ms)`. `:ets.update_counter/4` performs
  check-and-increment in a single atomic op, so concurrent callers cannot
  lose increments (the lookup-then-insert race the old integrations limiter
  had). The window_ms in the key lets `sweep/1` compute expiry across mixed
  window sizes sharing one table.
  """

  @spec check(:ets.table(), atom(), term(), {pos_integer(), pos_integer()}) ::
          :ok | {:error, :rate_limited}
  def check(table, scope, key, {limit, window_ms}) do
    now = System.system_time(:millisecond)
    bucket = div(now, window_ms)
    ets_key = {scope, key, window_ms, bucket}
    count = :ets.update_counter(table, ets_key, {2, 1}, {ets_key, 0})
    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  @doc "Deletes rows whose window has fully passed. Returns the delete count."
  @spec sweep(:ets.table()) :: non_neg_integer()
  def sweep(table) do
    now = System.system_time(:millisecond)

    match_spec = [
      {{{:_, :_, :"$1", :"$2"}, :_}, [{:"=<", {:*, {:+, :"$2", 1}, :"$1"}, now}], [true]}
    ]

    :ets.select_delete(table, match_spec)
  end
end
