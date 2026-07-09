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

  describe "refresh_token/2 per provider" do
    # provider => {token_url_key, client_id_env, client_secret_env}
    @providers %{
      google_drive: {:google_token_url, "GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET"},
      onedrive: {:onedrive_token_url, "ONEDRIVE_CLIENT_ID", "ONEDRIVE_CLIENT_SECRET"},
      dropbox: {:dropbox_token_url, "DROPBOX_APP_KEY", "DROPBOX_APP_SECRET"}
    }

    setup do
      # Each provider gets its own Bypass, token URL config, and env creds.
      envs =
        for {provider, {url_key, id_env, secret_env}} <- @providers, into: %{} do
          bypass = Bypass.open()
          prev_url = Application.get_env(:magus, url_key)
          Application.put_env(:magus, url_key, "http://localhost:#{bypass.port}/token")

          prev_id = System.get_env(id_env)
          prev_secret = System.get_env(secret_env)
          System.put_env(id_env, "#{provider}-client")
          System.put_env(secret_env, "#{provider}-secret")

          on_exit(fn ->
            Application.put_env(:magus, url_key, prev_url)

            if prev_id, do: System.put_env(id_env, prev_id), else: System.delete_env(id_env)

            if prev_secret,
              do: System.put_env(secret_env, prev_secret),
              else: System.delete_env(secret_env)
          end)

          {provider, bypass}
        end

      {:ok, bypasses: envs}
    end

    test "onedrive returns the rotated refresh token when the provider issues one", %{
      bypasses: bypasses
    } do
      bypass = bypasses[:onedrive]

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "ms-access",
            "refresh_token" => "ms-rotated",
            "expires_in" => 3600
          })
        )
      end)

      assert {:ok, tokens} = OAuth.refresh_token(:onedrive, "ms-old-refresh")
      assert tokens["access_token"] == "ms-access"
      assert tokens["refresh_token"] == "ms-rotated"
      assert is_binary(tokens["expires_at"])
    end

    test "dropbox keeps the caller's refresh token when the provider issues none", %{
      bypasses: bypasses
    } do
      bypass = bypasses[:dropbox]

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"access_token" => "dbx-access", "expires_in" => 14_400})
        )
      end)

      assert {:ok, tokens} = OAuth.refresh_token(:dropbox, "dbx-old-refresh")
      assert tokens["access_token"] == "dbx-access"
      assert tokens["refresh_token"] == "dbx-old-refresh"
      assert is_binary(tokens["expires_at"])
    end

    for provider <- [:google_drive, :onedrive, :dropbox] do
      test "#{provider} classifies invalid_grant as :reauth_required", %{bypasses: bypasses} do
        provider = unquote(provider)
        bypass = bypasses[provider]

        Bypass.expect_once(bypass, "POST", "/token", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
        end)

        assert {:error, :reauth_required} = OAuth.refresh_token(provider, "dead-refresh")
      end
    end
  end
end
