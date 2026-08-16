defmodule MagusWeb.ClientIP do
  @moduledoc """
  Resolves the client IP. When `config :magus, :client_ip_header` names a
  trusted proxy header (cloud prod: "fly-client-ip"), its FIRST value is
  parsed; absence or garbage falls back to `conn.remote_ip`. Never trust a
  header that is not explicitly configured — attackers pick their own
  rate-limit key otherwise. LiveViews get the IP via the session (the
  CaptureClientIP plug stores it), because `connect_info` x_headers only
  carries `x-`-prefixed names.
  """

  @session_key "client_ip"

  def session_key, do: @session_key

  @spec from_conn(Plug.Conn.t()) :: :inet.ip_address()
  def from_conn(conn) do
    case Application.get_env(:magus, :client_ip_header) do
      header when is_binary(header) ->
        conn
        |> Plug.Conn.get_req_header(header)
        |> List.first()
        |> parse()
        |> case do
          nil -> conn.remote_ip
          ip -> ip
        end

      _ ->
        conn.remote_ip
    end
  end

  @spec to_string(:inet.ip_address()) :: String.t()
  def to_string(ip), do: ip |> :inet.ntoa() |> Kernel.to_string()

  @spec from_session(map()) :: :inet.ip_address() | nil
  def from_session(session), do: session |> Map.get(@session_key) |> parse()

  defp parse(nil), do: nil

  defp parse(value) when is_binary(value) do
    value = value |> String.split(",") |> hd() |> String.trim()

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end
end
