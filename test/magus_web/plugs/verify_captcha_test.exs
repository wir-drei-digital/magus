defmodule MagusWeb.Plugs.VerifyCaptchaTest do
  use MagusWeb.ConnCase, async: false

  import Mox

  require Ash.Query

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:magus, :captcha)
    on_exit(fn -> Application.put_env(:magus, :captcha, original) end)
    :ok
  end

  defp enable! do
    Application.put_env(:magus, :captcha,
      impl: Magus.CaptchaImplMock,
      site_key: "sk",
      secret_key: "sec"
    )
  end

  defp user_exists?(email) do
    Magus.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.exists?(authorize?: false)
  end

  defp flash_error(conn), do: Phoenix.Flash.get(conn.assigns.flash, :error) || ""

  defp register_params(email) do
    %{
      "user" => %{
        "name" => "Test User",
        "email" => email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "accepted_terms" => "true",
        "accepted_age_requirement" => "true"
      }
    }
  end

  describe "captcha enabled" do
    test "a tokenless registration redirects to /register with a flash and creates no user", %{
      conn: conn
    } do
      enable!()
      email = "captcha-blocked-#{System.unique_integer([:positive])}@example.com"

      conn = post(conn, ~p"/auth/user/password/register", register_params(email))

      assert redirected_to(conn) == "/register"
      assert flash_error(conn) =~ "Captcha"
      refute user_exists?(email)
    end

    test "a tokenless magic-link request redirects to /sign-in", %{conn: conn} do
      enable!()

      conn =
        post(conn, ~p"/auth/user/magic_link/request", %{"user" => %{"email" => "x@y.z"}})

      assert redirected_to(conn) == "/sign-in"
      assert flash_error(conn) =~ "Captcha"
    end

    test "a non-matched /auth path is untouched even when enabled", %{conn: conn} do
      enable!()

      # /auth/user/password/sign_in is not one of VerifyCaptcha's routes, so the
      # plug must not call the captcha impl at all (no Mox expectation set —
      # an unexpected call would fail verify_on_exit!). Falls through to the
      # normal sign-in flow, which redirects to /sign-in on invalid creds.
      conn = post(conn, ~p"/auth/user/password/sign_in", %{"user" => %{}})

      refute flash_error(conn) =~ "Captcha"
    end
  end

  describe "captcha disabled (default)" do
    test "registration POST passes through untouched", %{conn: conn} do
      email = "captcha-disabled-#{System.unique_integer([:positive])}@example.com"

      conn = post(conn, ~p"/auth/user/password/register", register_params(email))

      refute flash_error(conn) =~ "Captcha"
      assert user_exists?(email)
    end

    test "magic-link request POST passes through untouched", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/user/magic_link/request", %{"user" => %{"email" => "x@y.z"}})

      refute flash_error(conn) =~ "Captcha"
    end
  end
end
