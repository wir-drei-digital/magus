defmodule Magus.Agents.RunLiveness do
  @moduledoc """
  Throttled execution-liveness pings for AgentRuns.

  `CleanupStale` reaps runs whose `last_heartbeat_at` is older than 2
  minutes, but nothing updated that timestamp during execution, so any run
  doing more than ~2 minutes of real work was falsely timed out. Streaming
  and tool plugins call `touch/1` on activity; at most one DB write per
  conversation per #{div(30_000, 1000)}s keeps the hot path cheap.

  The ETS table is owned by this GenServer but written by caller processes
  (`:public`); losing it on a crash only means one extra DB write.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Magus.Agents.AgentRun
  alias Magus.Repo

  @table :agent_run_liveness
  @touch_interval_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Throttled: updates last_heartbeat_at on :running runs targeting the conversation."
  @spec touch(String.t() | Ecto.UUID.t() | nil) :: :ok
  def touch(nil), do: :ok

  def touch(conversation_id) do
    conversation_id = to_string(conversation_id)
    now_ms = System.monotonic_time(:millisecond)

    if due?(conversation_id, now_ms) do
      :ets.insert(@table, {conversation_id, now_ms})

      now = DateTime.utc_now()

      {_count, _} =
        from(r in AgentRun,
          where: r.target_conversation_id == ^conversation_id and r.status == :running
        )
        |> Repo.update_all(set: [last_heartbeat_at: now, updated_at: now])
    end

    :ok
  rescue
    e ->
      Logger.warning(
        "RunLiveness.touch failed for #{inspect(conversation_id)}: #{Exception.message(e)}"
      )

      :ok
  end

  @doc "Test seam: clears the throttle entry so the next touch writes immediately."
  def reset_throttle(conversation_id) do
    :ets.delete(@table, to_string(conversation_id))
    :ok
  rescue
    _ -> :ok
  end

  defp due?(conversation_id, now_ms) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, last_ms}] -> now_ms - last_ms >= @touch_interval_ms
      [] -> true
    end
  rescue
    # Table missing (owner restarting): fail open, allow the write.
    _ -> true
  end
end
