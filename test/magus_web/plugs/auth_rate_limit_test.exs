defmodule MagusWeb.Plugs.AuthRateLimitTest do
  use MagusWeb.ConnCase, async: false

  setup do
    original = Application.get_env(:magus, :auth_rate_limits)
    on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
    :ok
  end

  test "register POSTs over the limit redirect to /register with a flash", %{conn: conn} do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, register: {0, :hour})
    conn = post(conn, ~p"/auth/user/password/register", %{"user" => %{}})
    assert redirected_to(conn) == "/register"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Too many"
  end

  test "disabled limits do not interfere", %{conn: conn} do
    Application.put_env(:magus, :auth_rate_limits, enabled: false)
    conn = post(conn, ~p"/auth/user/password/register", %{"user" => %{}})
    # falls through to the auth controller (no redirect to /register from the plug)
    refute conn.halted and redirected_to(conn) == "/register"
  end
end
