defmodule Magus.Knowledge.OAuthTest do
  use ExUnit.Case, async: false

  alias Magus.Knowledge.OAuth

  setup do
    bypass = Bypass.open()
    prev_url = Application.get_env(:magus, :google_token_url)
    Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")

    prev_id = System.get_env("GOOGLE_CLIENT_ID")
    prev_secret = System.get_env("GOOGLE_CLIENT_SECRET")
    System.put_env("GOOGLE_CLIENT_ID", "test-client")
    System.put_env("GOOGLE_CLIENT_SECRET", "test-secret")

    on_exit(fn ->
      Application.put_env(:magus, :google_token_url, prev_url)

      if prev_id,
        do: System.put_env("GOOGLE_CLIENT_ID", prev_id),
        else: System.delete_env("GOOGLE_CLIENT_ID")

      if prev_secret,
        do: System.put_env("GOOGLE_CLIENT_SECRET", prev_secret),
        else: System.delete_env("GOOGLE_CLIENT_SECRET")
    end)

    {:ok, bypass: bypass}
  end

  describe "refresh_google_token/1" do
    test "returns rotated tokens on success, keeping the old refresh token when none is issued",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"access_token" => "new-access", "expires_in" => 3600})
        )
      end)

      assert {:ok, tokens} = OAuth.refresh_google_token("old-refresh")
      assert tokens["access_token"] == "new-access"
      assert tokens["refresh_token"] == "old-refresh"
      assert is_binary(tokens["expires_at"])
    end

    test "classifies invalid_grant as :reauth_required", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      assert {:error, :reauth_required} = OAuth.refresh_google_token("dead-refresh")
    end

    test "returns a transient error for a 500 from the token endpoint", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "server_error"}))
      end)

      assert {:error, {:refresh_failed, 500, _body}} = OAuth.refresh_google_token("some-refresh")
    end
  end

  describe "google_credentials/0" do
    test "errors when env is missing" do
      System.delete_env("GOOGLE_CLIENT_ID")
      assert {:error, :missing_oauth_config} = OAuth.google_credentials()
    end
  end
end
