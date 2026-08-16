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

  defp register_params(email, token \\ nil) do
    base = %{
      "user" => %{
        "name" => "Test User",
        "email" => email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "accepted_terms" => "true",
        "accepted_age_requirement" => "true"
      }
    }

    # The Turnstile widget's response token is a sibling form field, not
    # namespaced under "user[...]" — mirrors how MagusWeb.CaptchaComponents
    # renders it (outside the `user[...]` input group).
    if token, do: Map.put(base, "cf-turnstile-response", token), else: base
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

    test "a valid token passes the plug and reaches the auth controller", %{conn: conn} do
      enable!()
      email = "captcha-valid-#{System.unique_integer([:positive])}@example.com"

      expect(Magus.CaptchaImplMock, :verify, fn %{"cf-turnstile-response" => "tok"}, _ip ->
        {:ok, %{"success" => true}}
      end)

      conn = post(conn, ~p"/auth/user/password/register", register_params(email, "tok"))

      refute flash_error(conn) =~ "Captcha"
      assert user_exists?(email)
    end

    test "cloudflare rejection (success: false) denies with the generic captcha flash", %{
      conn: conn
    } do
      enable!()
      email = "captcha-rejected-#{System.unique_integer([:positive])}@example.com"

      expect(Magus.CaptchaImplMock, :verify, fn _params, _ip ->
        {:error, %{"success" => false}}
      end)

      conn = post(conn, ~p"/auth/user/password/register", register_params(email, "bad-tok"))

      assert redirected_to(conn) == "/register"
      assert flash_error(conn) =~ "Captcha verification failed"
      refute user_exists?(email)
    end

    test "a transport failure denies with the distinct verification-unavailable flash", %{
      conn: conn
    } do
      enable!()
      email = "captcha-timeout-#{System.unique_integer([:positive])}@example.com"

      expect(Magus.CaptchaImplMock, :verify, fn _params, _ip -> {:error, :timeout} end)

      conn = post(conn, ~p"/auth/user/password/register", register_params(email, "tok"))

      assert redirected_to(conn) == "/register"
      assert flash_error(conn) =~ "temporarily unavailable"
      refute user_exists?(email)
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
