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

  @doc """
  Finalizes a knowledge-source OAuth connect for the SPA.

  The shared OAuth callback stashes the provider tokens in the session and
  redirects to `/settings/knowledge?wizard_provider=<key>`; the SPA posts
  here so the source is created server-side from the session tokens. The tokens
  never reach the browser, and the session copy is consumed (one-time).
  """
  def knowledge_oauth_finalize(conn, %{"provider" => provider}) when is_binary(provider) do
    user = conn.assigns.current_user

    case Plug.Conn.get_session(conn, :knowledge_oauth_tokens) do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "No pending authorization. Start the connect flow again."})

      tokens ->
        conn = Plug.Conn.delete_session(conn, :knowledge_oauth_tokens)

        case Magus.Knowledge.Connect.connect_and_create(provider, tokens, actor: user) do
          {:ok, source} ->
            json(conn, %{
              source: %{
                id: source.id,
                name: source.name,
                provider: to_string(source.provider),
                status: to_string(source.status)
              }
            })

          {:error, message} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: message})
        end
    end
  end

  def knowledge_oauth_finalize(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing provider."})
  end
end
