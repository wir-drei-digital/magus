defmodule Magus.MCP.Discovery do
  @moduledoc """
  Connects to an MCP server, lists its tools, and caches normalized definitions
  on the `Server` row so catalog search can run offline. Connections are short
  lived (one per discovery).
  """

  require Logger

  alias Magus.MCP
  alias Magus.MCP.{Client, ClientManager, ErrorSanitizer, ToolAdapter}

  @spec test_connection(MCP.Server.t(), struct()) :: {:ok, [map()]} | {:error, term()}
  def test_connection(%MCP.Server{} = server, actor) do
    headers = headers_for(server, actor)

    ClientManager.with_client(server, headers, fn client ->
      case Client.list_tools(client) do
        {:ok, tools} -> {:ok, normalize_tools(tools)}
        {:error, _} = err -> err
      end
    end)
  end

  # One malformed remote tool must not crash the whole discovery (spec 8.2):
  # keep the valid ones, log+drop the invalid ones.
  defp normalize_tools(tools) do
    Enum.flat_map(tools, fn raw ->
      case ToolAdapter.normalize_tool(raw) do
        {:ok, tool} ->
          [tool]

        {:error, reason} ->
          Logger.warning("MCP discovery dropped a malformed tool: #{inspect(reason)}")
          []
      end
    end)
  end

  @spec discover_and_cache(MCP.Server.t(), struct()) :: {:ok, MCP.Server.t()} | {:error, term()}
  def discover_and_cache(%MCP.Server{} = server, actor) do
    case test_connection(server, actor) do
      {:ok, normalized} ->
        with {:ok, updated} <-
               MCP.update_server_cached_tools(server, %{cached_tools: normalized}, actor: actor),
             {:ok, _} <-
               MCP.record_server_reachability(updated, %{reachability: :ok, last_error: nil},
                 actor: actor
               ) do
          {:ok, %{updated | reachability: :ok}}
        else
          {:error, _} = err -> err
        end

      {:error, reason} ->
        # Store only a sanitized category in the viewer-readable column; the full
        # reason goes to the operator log.
        Logger.warning("MCP discovery failed for server #{server.id}: #{inspect(reason)}")

        _ =
          MCP.record_server_reachability(
            server,
            %{reachability: :error, last_error: ErrorSanitizer.categorize(reason)},
            actor: actor
          )

        {:error, reason}
    end
  end

  # Build request headers from the actor's stored credential for static-header servers.
  defp headers_for(%MCP.Server{auth_type: :static_header} = server, actor) do
    case MCP.get_credential_for_server(server.id, actor: actor) do
      {:ok, %MCP.ServerCredential{static_headers: headers}} when is_map(headers) -> headers
      _ -> %{}
    end
  end

  defp headers_for(_server, _actor), do: %{}
end
