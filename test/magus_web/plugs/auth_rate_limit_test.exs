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

    refute conn.halted
    # Falls through to the auth controller, which fails validation on the
    # empty params and redirects to /sign-in — the plug's own /register
    # redirect (asserted in the test above) never fires.
    assert redirected_to(conn) == "/sign-in"
  end

  test "limiting is keyed per IP: a different remote_ip has its own budget", %{conn: conn} do
    Application.put_env(:magus, :auth_rate_limits, enabled: true, register: {1, :hour})

    ip_a = %{conn | remote_ip: {10, 0, 0, 1}}
    ip_b = %{conn | remote_ip: {10, 0, 0, 2}}

    # First POST from IP A is within its budget: falls through to the
    # controller (redirects to /sign-in on the invalid/empty params).
    first = post(ip_a, ~p"/auth/user/password/register", %{"user" => %{}})
    assert redirected_to(first) == "/sign-in"

    # Second POST from the SAME IP trips its budget.
    second = post(ip_a, ~p"/auth/user/password/register", %{"user" => %{}})
    assert redirected_to(second) == "/register"

    # A POST from a DIFFERENT IP has its own, untouched budget.
    third = post(ip_b, ~p"/auth/user/password/register", %{"user" => %{}})
    assert redirected_to(third) == "/sign-in"
  end
end
