defmodule Magus.Graph.Connection do
  @moduledoc """
  Redix-based connection pool for FalkorDB.

  FalkorDB speaks the Redis protocol. We use a pool of N redix processes
  named `:falkordb_0`, `:falkordb_1`, ... and dispatch commands by random
  selection across the pool. Random dispatch is sufficient at our scale;
  true round-robin would require :atomics or a counter process.
  """

  def child_spec(_opts) do
    config = Application.fetch_env!(:magus, Magus.Graph)
    pool_size = Keyword.get(config, :pool_size, 10)
    host = Keyword.fetch!(config, :host)
    port = Keyword.fetch!(config, :port)

    # FalkorDB speaks Redis, so AUTH is sent via Redix's `:password` option.
    # Only include it when configured: dev/test typically run an
    # unauthenticated local instance, while prod requires it (see
    # runtime.exs). Passing `password: nil` to Redix would still skip AUTH,
    # but omitting it keeps the child opts clean.
    base_opts = [host: host, port: port]

    redix_opts =
      case Keyword.get(config, :password) do
        password when is_binary(password) and password != "" ->
          Keyword.put(base_opts, :password, password)

        _ ->
          base_opts
      end

    children =
      for i <- 0..(pool_size - 1) do
        Supervisor.child_spec(
          {Redix, Keyword.put(redix_opts, :name, :"falkordb_#{i}")},
          id: {:falkordb, i}
        )
      end

    %{
      id: __MODULE__,
      start:
        {Supervisor, :start_link, [children, [strategy: :one_for_one, name: __MODULE__.Sup]]},
      type: :supervisor
    }
  end

  def command(cmd, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    Redix.command(random_conn(), cmd, timeout: timeout)
  end

  defp random_conn do
    pool_size =
      Application.fetch_env!(:magus, Magus.Graph)
      |> Keyword.get(:pool_size, 10)

    :"falkordb_#{:rand.uniform(pool_size) - 1}"
  end
end
