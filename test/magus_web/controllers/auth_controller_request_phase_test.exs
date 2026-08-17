defmodule MagusWeb.AuthControllerRequestPhaseTest do
  @moduledoc """
  Request-phase auth actions (magic-link request, password reset request)
  return bare :ok, so AshAuthentication's dispatcher calls
  AuthController.success/4 with user = nil. The generic success clause
  dereferences the user for billing-edition checkout routing, which 500s in
  the commercial edition (magus-iw4z) — and its "You are now signed in"
  flash is wrong for a mail request in any edition. These tests pin the
  dedicated nil-user clause.
  """
  use MagusWeb.ConnCase, async: false

  defp flash_info(conn), do: Phoenix.Flash.get(conn.assigns.flash, :info) || ""

  describe "magic-link request over raw HTTP" do
    test "succeeds with a mail-request flash and no sign-in claim", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/user/magic_link/request", %{"user" => %{"email" => "req@example.com"}})

      assert redirected_to(conn) == "/sign-in"
      assert flash_info(conn) =~ "sign-in link"
      refute flash_info(conn) =~ "signed in"
    end

    test "does not clear a pending invite token from the session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{invite_token: "pending-invite"})
        |> post(~p"/auth/user/magic_link/request", %{"user" => %{"email" => "req@example.com"}})

      assert get_session(conn, :invite_token) == "pending-invite"
    end
  end

  describe "password reset request over raw HTTP" do
    test "succeeds with a non-committal flash and no sign-in claim", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/user/password/reset_request", %{
          "user" => %{"email" => "req@example.com"}
        })

      assert redirected_to(conn) == "/sign-in"
      assert flash_info(conn) =~ "inbox"
      refute flash_info(conn) =~ "signed in"
    end
  end
end
