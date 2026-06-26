defmodule MagusWeb.SandboxPreviewController do
  @moduledoc """
  Authenticated reverse proxy for sandbox service previews.

  Routes requests through the sandbox provider's proxy_request callback.
  Each provider handles the transport details (Sprites uses WS TCP tunnel,
  Modal uses Connect Tokens).

  The flow:
  1. User hits /sandbox/preview/:conversation_id/*path
  2. Controller verifies user is authenticated and owns the conversation's sandbox
  3. Builds a structured request map from the browser request
  4. Sends it through the provider's proxy_request
  5. Relays the response back to the user
  """
  use MagusWeb, :controller

  alias Magus.Chat
  alias Magus.Sandbox
  alias Magus.Sandbox.Provider

  require Logger

  # Hop-by-hop headers that should not be forwarded in requests
  @hop_by_hop_headers ~w(
    connection keep-alive proxy-authenticate proxy-authorization
    te trailers transfer-encoding upgrade
  )

  # Headers to strip from forwarded requests (security)
  @stripped_request_headers @hop_by_hop_headers ++ ~w(host cookie authorization)

  # Headers to strip from upstream responses (security)
  @stripped_response_headers @hop_by_hop_headers ++
                               ~w(content-security-policy content-security-policy-report-only set-cookie)

  # Allowed HTTP methods for proxying
  @allowed_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  def proxy(conn, %{"conversation_id" => conversation_id} = params) do
    current_user = conn.assigns[:current_user]

    if is_nil(current_user) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Authentication required"})
    else
      case get_authorized_sandbox(conversation_id, current_user) do
        {:ok, sandbox} ->
          forward_request(conn, sandbox, params)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Sandbox not found"})
      end
    end
  end

  defp get_authorized_sandbox(conversation_id, user) do
    case Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
      {:ok, [%{state: :active, service_port: port} = sandbox]} when is_integer(port) ->
        {:ok, sandbox}

      _ ->
        # Fall back to share-link-based access (authenticated users only, no public)
        with {:ok, [%{state: :active, service_port: port} = sandbox]}
             when is_integer(port) <-
               Sandbox.get_sandbox_by_conversation(conversation_id, authorize?: false),
             true <- sandbox_accessible_via_share_link?(conversation_id, user) do
          {:ok, sandbox}
        else
          _ -> {:error, :not_found}
        end
    end
  end

  defp sandbox_accessible_via_share_link?(conversation_id, _user) do
    case Chat.get_active_share_links(conversation_id, authorize?: false) do
      {:ok, links} ->
        Enum.any?(links, &(&1.access_type in [:public, :authenticated]))

      _ ->
        false
    end
  end

  defp forward_request(conn, sandbox, params) do
    if conn.method in @allowed_methods do
      do_forward(conn, sandbox, params)
    else
      conn
      |> put_status(405)
      |> json(%{error: "Method not allowed"})
    end
  end

  defp do_forward(conn, sandbox, params) do
    case read_full_body(conn) do
      {:ok, body, conn} ->
        request = build_structured_request(conn, params, body)
        client = Provider.client_for(sandbox)

        case client.proxy_request(sandbox.sprite_id, sandbox.service_port, request) do
          {:ok, %{status: status, headers: headers, body: resp_body}} ->
            conn
            |> merge_upstream_headers(headers)
            |> send_resp(status, resp_body)

          {:error, reason} ->
            Logger.warning(
              "Sandbox proxy error: #{inspect(reason)} " <>
                "(sandbox=#{sandbox.sprite_id} port=#{sandbox.service_port})"
            )

            conn
            |> put_status(502)
            |> json(%{error: "Service unavailable"})
        end

      {:error, _reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "Bad request"})
    end
  end

  defp build_structured_request(conn, params, body) do
    path_segments = Map.get(params, "path", [])
    path = "/" <> Enum.join(path_segments, "/")
    query_string = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
    request_uri = "#{path}#{query_string}"

    # Filter hop-by-hop, security, and framing headers; we set our own
    headers =
      conn.req_headers
      |> Enum.reject(fn {name, _} ->
        name in @stripped_request_headers or name in ["content-length", "transfer-encoding"]
      end)

    # Add standard proxy headers
    headers = [
      {"host", "localhost"},
      {"connection", "close"},
      {"content-length", Integer.to_string(byte_size(body))} | headers
    ]

    %{
      method: conn.method,
      path: request_uri,
      headers: headers,
      body: body
    }
  end

  defp read_full_body(conn, acc \\ []) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([body | acc])), conn}

      {:more, partial, conn} ->
        read_full_body(conn, [partial | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_upstream_headers(conn, headers) do
    headers
    |> Enum.reject(fn {name, _} ->
      String.downcase(name) in @stripped_response_headers
    end)
    |> Enum.reduce(conn, fn {name, value}, acc ->
      put_resp_header(acc, String.downcase(name), value)
    end)
  end
end
