defmodule MagusWeb.Plugs.AuthRateLimit do
  @moduledoc """
  IP-keyed rate limits on the auth POST endpoints (signup-abuse spec).
  302 + flash on limit (browser form flow, not a bare 429). Ordered before
  captcha verification so hammering never costs a siteverify call.
  """
  @behaviour Plug

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]
  import Plug.Conn

  alias Magus.Accounts.AuthRateLimiter
  alias MagusWeb.ClientIP

  @routes %{
    ["auth", "user", "password", "register"] => {:register, "/register"},
    ["auth", "user", "password", "sign_in"] => {:sign_in, "/sign-in"},
    ["auth", "user", "magic_link", "request"] => {:magic_link_http, "/sign-in"}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Map.fetch(@routes, conn.path_info) do
      {:ok, {scope, redirect_to}} -> enforce(conn, scope, redirect_to)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  # The HTTP magic-link route shares the register budget shape but is
  # dominated by the action-level per-email + global limits (Task 2
  # wrappers); IP limiting here reuses the :register scope numbers.
  defp enforce(conn, :magic_link_http, redirect_to), do: enforce(conn, :register, redirect_to)

  defp enforce(conn, scope, redirect_to) do
    case AuthRateLimiter.check(scope, ClientIP.from_conn(conn)) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, gettext("Too many attempts. Please try again later."))
        |> redirect(to: redirect_to)
        |> halt()
    end
  end
end
