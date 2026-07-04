defmodule Magus.Knowledge.Connectors.GoogleDriveTest do
  # async: false: the reactive-refresh tests mutate global Application env
  # (:google_drive_base_url, :google_token_url) and System env (GOOGLE_CLIENT_*).
  use ExUnit.Case, async: false

  alias Magus.Knowledge.Connectors.GoogleDrive

  describe "connect/1" do
    test "creates connection with access token" do
      assert {:ok, conn} = GoogleDrive.connect(%{"access_token" => "ya29.test"})
      assert conn.access_token == "ya29.test"
      assert conn.refresh_token == nil
    end

    test "creates connection with access and refresh tokens" do
      config = %{"access_token" => "ya29.test", "refresh_token" => "1//refresh"}
      assert {:ok, conn} = GoogleDrive.connect(config)
      assert conn.access_token == "ya29.test"
      assert conn.refresh_token == "1//refresh"
    end

    test "fails without access token" do
      assert {:error, :missing_access_token} = GoogleDrive.connect(%{})
    end

    test "fails with empty access token" do
      assert {:error, :missing_access_token} = GoogleDrive.connect(%{"access_token" => ""})
    end
  end

  describe "reactive refresh classifies a dead refresh token" do
    setup do
      drive = Bypass.open()
      token = Bypass.open()
      prev_base = Application.get_env(:magus, :google_drive_base_url)
      prev_token = Application.get_env(:magus, :google_token_url)
      Application.put_env(:magus, :google_drive_base_url, "http://localhost:#{drive.port}")
      Application.put_env(:magus, :google_token_url, "http://localhost:#{token.port}/token")

      prev_id = System.get_env("GOOGLE_CLIENT_ID")
      prev_secret = System.get_env("GOOGLE_CLIENT_SECRET")
      System.put_env("GOOGLE_CLIENT_ID", "id")
      System.put_env("GOOGLE_CLIENT_SECRET", "secret")

      on_exit(fn ->
        Application.put_env(:magus, :google_drive_base_url, prev_base)
        Application.put_env(:magus, :google_token_url, prev_token)

        if prev_id,
          do: System.put_env("GOOGLE_CLIENT_ID", prev_id),
          else: System.delete_env("GOOGLE_CLIENT_ID")

        if prev_secret,
          do: System.put_env("GOOGLE_CLIENT_SECRET", prev_secret),
          else: System.delete_env("GOOGLE_CLIENT_SECRET")
      end)

      {:ok, drive: drive, token: token}
    end

    test "returns :reauth_required when refresh yields invalid_grant", %{
      drive: drive,
      token: token
    } do
      Bypass.expect(drive, "GET", "/files", fn conn -> Plug.Conn.resp(conn, 401, "{}") end)

      Bypass.expect_once(token, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      {:ok, conn} =
        GoogleDrive.connect(%{
          "access_token" => "expired",
          "refresh_token" => "dead"
        })

      assert {:error, :reauth_required} =
               GoogleDrive.list_items(conn, %{external_id: "root"}, %{
                 "folders" => ["root"]
               })
    end
  end
end
