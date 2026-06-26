defmodule MagusWeb.Api.Plugs.RequireTokenScope do
  @moduledoc """
  Enforces scope on the assigned `:current_token`.

  Read tokens may only issue GET/HEAD/OPTIONS. Any state-changing
  method (POST/PUT/PATCH/DELETE) requires a `:write`-scoped token.

  Must run after `MagusWeb.Api.Plugs.ApiTokenAuthPlug`.
  """

  import Plug.Conn

  @write_methods ~w(POST PUT PATCH DELETE)

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      is_nil(conn.assigns[:current_token]) ->
        send_error(conn, 401, "missing_token", "Authentication required")

      conn.method in @write_methods and conn.assigns.current_token.scope != :write ->
        send_error(
          conn,
          403,
          "insufficient_scope",
          "This token has scope :read but the operation requires :write"
        )

      true ->
        conn
    end
  end

  defp send_error(conn, status, code, message) do
    body = Jason.encode!(%{"error" => %{"code" => code, "message" => message}})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
