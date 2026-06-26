defmodule Magus.Models.CatalogSync.Server do
  @moduledoc """
  Serializes CatalogSync reloads: LLMDB.load swaps the whole catalog, so
  concurrent rebuilds must not interleave. Coalesces bursts (a reload
  requested while one is queued is a no-op).

  All reloads — the write-triggered coalesced cast (`request_reload`) and the
  admin "Refresh registry" button (`refresh/2`) — run through this single
  process so a manual snapshot fetch can never interleave with a model/provider
  write's reload.

  Boot behavior: the initial DB -> LLMDB sync is queued as a normal reload
  so supervisor startup never blocks on the DB (or a remote snapshot fetch);
  LLMDB's packaged catalog serves until it completes. Failure (e.g. fresh
  install before migrations) logs a warning and leaves the packaged/config
  catalog in place.
  """

  use GenServer
  require Logger

  alias Magus.Models.CatalogSync

  @refresh_timeout 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Serialized manual refresh, returning the guarded reload result for a flash.

  When the server is running, the reload runs INSIDE it (via a `call`), so it
  serializes against the coalesced write-triggered casts — a manual snapshot
  fetch can't interleave with a write's reload. When the server is NOT running
  (e.g. some unit tests), falls back to a direct guarded reload so callers
  still work offline.

  `snapshot_source` is forwarded to `CatalogSync.reload/1` (e.g.
  `{:github_releases, ref: :latest}` to pull the newest published registry).
  Uses a generous `timeout` (default #{@refresh_timeout}ms) to cover the
  network fetch + full catalog load.
  """
  @spec refresh(term(), timeout()) :: :ok | {:error, term()}
  def refresh(snapshot_source, timeout \\ @refresh_timeout) do
    case Process.whereis(__MODULE__) do
      nil ->
        CatalogSync.guarded_reload(snapshot_source: snapshot_source)

      pid ->
        GenServer.call(pid, {:refresh, snapshot_source}, timeout)
    end
  end

  @impl true
  def init(_opts) do
    send(self(), :do_reload)
    {:ok, %{pending: true}}
  end

  @impl true
  def handle_cast(:reload, %{pending: true} = state), do: {:noreply, state}

  def handle_cast(:reload, state) do
    send(self(), :do_reload)
    {:noreply, %{state | pending: true}}
  end

  @impl true
  def handle_call({:refresh, snapshot_source}, _from, state) do
    # Serialized against the coalesced cast path: this runs in the same
    # process, so no write-triggered reload can interleave. `pending` is left
    # untouched — any cast queued while this call ran still fires its own
    # :do_reload afterward.
    result = CatalogSync.guarded_reload(snapshot_source: snapshot_source)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:do_reload, state) do
    case CatalogSync.guarded_reload() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("CatalogSync catalog reload failed: #{inspect(reason)}")
    end

    {:noreply, %{state | pending: false}}
  end
end
