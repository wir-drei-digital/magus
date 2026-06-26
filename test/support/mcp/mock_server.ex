defmodule Magus.MCP.MockServer do
  @moduledoc """
  A Bypass-backed mock MCP server speaking enough of Streamable HTTP for client
  tests: it answers `initialize`, swallows `notifications/initialized`, and
  replies to `tools/list` and `tools/call` with canned JSON-RPC results.

  ## What the anubis (1.6.2) Streamable HTTP handshake needs

  The real `Anubis.Client` drives a handshake against this mock, so the wire
  framing has to match what anubis actually sends/expects:

    * Every POST advertises `accept: application/json, text/event-stream`. We
      reply with a single `application/json` JSON-RPC object; anubis's transport
      forwards that body straight to the client, so SSE framing is not required.
    * The `initialize` result MUST carry `serverInfo` (anubis pattern-matches on
      it to mark the client initialized) plus a `protocolVersion` and a
      `capabilities.tools` map the client accepts.
    * We issue an `Mcp-Session-Id` response header on `initialize`. anubis echoes
      it back via the `mcp-session-id` request header on later requests and sends
      a `DELETE` carrying it when the client shuts down. The mock is stateless and
      does not validate the echoed id; anubis only attaches it when present, so no
      server-side session bookkeeping is needed for the handshake to complete.
    * Notifications (no `id`) get a bare `202 Accepted`.

  ## Usage

      bypass = Magus.MCP.MockServer.start(tools: [%{"name" => "echo", ...}])
      url = "http://127.0.0.1:\#{bypass.port}"
  """

  @session_id "mock-session-id"

  @doc """
  Opens a Bypass server stubbed to behave like an MCP server.

  Options:

    * `:tools` - the tool-def maps returned by `tools/list`
      (default: a single `echo` tool).
    * `:debug` - when `true`, logs every inbound request (method, `accept`,
      `mcp-session-id`, body) to aid handshake debugging.
  """
  def start(opts \\ []) do
    bypass = Bypass.open()

    tools =
      Keyword.get(opts, :tools, [
        %{"name" => "echo", "description" => "Echo", "inputSchema" => %{}}
      ])

    debug? = Keyword.get(opts, :debug, false)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      maybe_log(debug?, conn, request)
      respond(conn, request, tools)
    end)

    # anubis sends a DELETE with the session id when the client shuts down.
    Bypass.stub(bypass, "DELETE", "/mcp", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    bypass
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _tools) do
    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", @session_id)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "serverInfo" => %{"name" => "mock", "version" => "1.0.0"},
        "capabilities" => %{"tools" => %{}}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/list", "id" => id}, tools) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id}, _tools) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => false}
    })
  end

  defp respond(conn, %{"method" => "ping", "id" => id}, _tools) do
    json(conn, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})
  end

  # Notifications (no id) get a 202 with no body.
  defp respond(conn, _notification, _tools) do
    Plug.Conn.resp(conn, 202, "")
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  defp maybe_log(false, _conn, _request), do: :ok

  defp maybe_log(true, conn, request) do
    require Logger

    Logger.debug("""
    [MockServer] #{request["method"]}
      accept: #{Plug.Conn.get_req_header(conn, "accept") |> Enum.join(", ")}
      mcp-session-id: #{Plug.Conn.get_req_header(conn, "mcp-session-id") |> Enum.join(", ")}
      body: #{inspect(request)}
    """)
  end
end
