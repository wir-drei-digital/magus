defmodule MagusWeb.Rpc.RpcController do
  @moduledoc """
  HTTP transport for the AshTypescript RPC layer used by the SvelteKit
  workbench (`frontend/`). Authentication comes from the `:rpc` router
  pipeline (session cookie, same origin); the actor is set via
  `AshAuthentication.Plug.Helpers.set_actor/2` and resolved by Ash policies
  exactly like every other caller.

  `socket_token/2` issues a short-lived `Phoenix.Token` so the SPA can
  authenticate the `/socket` WebSocket without depending on cookie semantics
  — the same flow future native (Capacitor) and CLI clients will use.
  """
  use MagusWeb, :controller

  @socket_token_salt "user socket"
  # One day; the SPA fetches a fresh token on every socket (re)connect.
  @socket_token_max_age 86_400

  def socket_token_salt, do: @socket_token_salt
  def socket_token_max_age, do: @socket_token_max_age

  def run(conn, params) do
    json(conn, AshTypescript.Rpc.run_action(:magus, conn, params))
  end

  def validate(conn, params) do
    json(conn, AshTypescript.Rpc.validate_action(:magus, conn, params))
  end

  def socket_token(conn, _params) do
    user = conn.assigns.current_user
    token = Phoenix.Token.sign(MagusWeb.Endpoint, @socket_token_salt, user.id)
    json(conn, %{token: token})
  end
end
