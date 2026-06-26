defmodule Magus.MCP.ClientManager do
  @moduledoc """
  Starts and stops `anubis_mcp` clients under the MCP DynamicSupervisor.

  This plan uses SHORT-LIVED clients for discovery: `with_client/2,3` starts a
  client, awaits initialization, runs the function, and always stops the client.
  Long-lived reused clients with idle-reaping and refresh-on-401 arrive in the
  execution plan.
  """

  @client_info %{"name" => "Magus", "version" => "1.0.0"}
  @protocol_version "2025-06-18"

  defp init_timeout_ms do
    Application.get_env(:magus, Magus.MCP, [])[:init_timeout_ms] || 10_000
  end

  @spec with_client(Magus.MCP.Server.t(), (GenServer.server() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_client(server, fun), do: with_client(server, %{}, fun)

  @spec with_client(Magus.MCP.Server.t(), map(), (GenServer.server() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_client(%Magus.MCP.Server{} = server, headers, fun)
      when is_map(headers) and is_function(fun, 1) do
    nonce = System.unique_integer([:positive])
    name = registry_name({:discovery, server.id, nonce})
    transport_name = registry_name({:discovery_transport, server.id, nonce})

    case start_client(server, headers, name, transport_name) do
      {:ok, pid} ->
        try do
          case await_ready(name) do
            :ok -> fun.(name)
            {:error, _} = err -> err
          end
        after
          DynamicSupervisor.terminate_child(Magus.MCP.ClientDynamicSupervisor, pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp registry_name(key), do: {:via, Registry, {Magus.MCP.ClientRegistry, key}}

  # Wrap anubis's blocking `await_ready` (parks the caller until the handshake
  # completes, returns immediately if capabilities are already present) and map
  # its exits to explicit error tuples so a real client crash surfaces instead of
  # masquerading as a timeout.
  defp await_ready(name) do
    Anubis.Client.await_ready(name, timeout: init_timeout_ms())
  catch
    :exit, {:timeout, _} -> {:error, :initialization_timeout}
    :exit, {:noproc, _} -> {:error, :process_not_found}
    # anubis replies to :await_ready with an {:error, reason} call result when the
    # transport fails before the handshake (e.g. econnrefused), which surfaces as
    # an exit. Map any other exit to a clean error tuple rather than propagating it.
    :exit, reason -> {:error, reason}
  end

  defp start_client(server, headers, name, transport_name) do
    # Re-validate the URL at dial time: Finch resolves DNS fresh on connect, so a
    # hostname that resolved to a public IP at create/update time could now point
    # at a private/internal address (DNS rebinding). The config-gated
    # allow_private_urls bypass keeps dev/test (Bypass on 127.0.0.1) working.
    case Magus.MCP.SafeUrl.validate(server.url) do
      :ok ->
        transport =
          {:streamable_http, base_url: server.url, mcp_path: server.mcp_path, headers: headers}

        # A via-tuple client name requires an explicit transport_name; anubis raises
        # otherwise (it only auto-derives transport names from atom client names).
        # These are one-shot discovery clients: use `restart: :transient` so an
        # abnormal exit is not auto-restarted under the same Registry name (which
        # would leak a process the caller can no longer terminate).
        spec =
          %{
            id: name,
            start:
              {Anubis.Client, :start_link,
               [
                 [
                   name: name,
                   transport_name: transport_name,
                   transport: transport,
                   client_info: @client_info,
                   capabilities: %{},
                   protocol_version: @protocol_version
                 ]
               ]},
            type: :supervisor,
            restart: :transient
          }

        case DynamicSupervisor.start_child(Magus.MCP.ClientDynamicSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:ssrf_blocked, reason}}
    end
  end
end
