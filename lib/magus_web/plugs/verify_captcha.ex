defmodule MagusWeb.Plugs.VerifyCaptcha do
  @moduledoc """
  Captcha verification for the two POST routes that create accounts / send
  signup mail. Fail closed: an unreachable siteverify rejects the submit.
  """
  @behaviour Plug

  use Gettext, backend: MagusWeb.Gettext

  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]
  import Plug.Conn

  alias MagusWeb.ClientIP

  @routes %{
    ["auth", "user", "password", "register"] => "/register",
    ["auth", "user", "magic_link", "request"] => "/sign-in"
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case Map.fetch(@routes, conn.path_info) do
      {:ok, redirect_to} -> enforce(conn, redirect_to)
      :error -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp enforce(conn, redirect_to) do
    case Magus.Captcha.verify(conn.params, ClientIP.from_conn(conn)) do
      :ok ->
        conn

      {:error, :verification_unavailable} ->
        deny(
          conn,
          redirect_to,
          gettext("Verification is temporarily unavailable. Please try again.")
        )

      {:error, _missing_or_invalid} ->
        deny(conn, redirect_to, gettext("Captcha verification failed. Please try again."))
    end
  end

  defp deny(conn, redirect_to, message) do
    conn |> put_flash(:error, message) |> redirect(to: redirect_to) |> halt()
  end
end
