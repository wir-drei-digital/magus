defmodule Magus.Knowledge.TokenManagerTest do
  use Magus.ResourceCase, async: false

  alias Magus.Knowledge
  alias Magus.Knowledge.TokenManager

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:magus, :google_token_url)
    prev_dbx = Application.get_env(:magus, :dropbox_token_url)
    Application.put_env(:magus, :google_token_url, "http://localhost:#{bypass.port}/token")
    Application.put_env(:magus, :dropbox_token_url, "http://localhost:#{bypass.port}/token")
    System.put_env("GOOGLE_CLIENT_ID", "id")
    System.put_env("GOOGLE_CLIENT_SECRET", "secret")
    System.put_env("DROPBOX_APP_KEY", "key")
    System.put_env("DROPBOX_APP_SECRET", "secret")

    on_exit(fn ->
      Application.put_env(:magus, :google_token_url, prev)
      Application.put_env(:magus, :dropbox_token_url, prev_dbx)
    end)

    {:ok, bypass: bypass}
  end

  defp gdrive_source(user, auth_config) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "GD", provider: :google_drive, auth_config: auth_config},
        actor: user
      )

    {:ok, source} = Knowledge.update_source_status(source, %{status: :active}, actor: user)
    source
  end

  defp dropbox_source(user, auth_config) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "DBX", provider: :dropbox, auth_config: auth_config},
        actor: user
      )

    {:ok, source} = Knowledge.update_source_status(source, %{status: :active}, actor: user)
    source
  end

  defp expired_iso, do: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
  defp future_iso, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

  test "refreshes and persists when the access token is expired", %{bypass: bypass} do
    user = generate(user())

    source =
      gdrive_source(user, %{
        "access_token" => "old",
        "refresh_token" => "r",
        "expires_at" => expired_iso()
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "fresh", "expires_in" => 3600}))
    end)

    assert {:ok, refreshed} = TokenManager.ensure_fresh(source)
    assert refreshed.auth_config["access_token"] == "fresh"

    {:ok, reloaded} = Knowledge.get_source(source.id, actor: user)
    assert reloaded.auth_config["access_token"] == "fresh"
  end

  test "refreshes and persists a dropbox source when the access token is expired", %{
    bypass: bypass
  } do
    user = generate(user())

    source =
      dropbox_source(user, %{
        "access_token" => "old",
        "refresh_token" => "r",
        "expires_at" => expired_iso()
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"access_token" => "dbx-fresh", "expires_in" => 14_400})
      )
    end)

    assert {:ok, refreshed} = TokenManager.ensure_fresh(source)
    assert refreshed.auth_config["access_token"] == "dbx-fresh"

    {:ok, reloaded} = Knowledge.get_source(source.id, actor: user)
    assert reloaded.auth_config["access_token"] == "dbx-fresh"
  end

  test "does not call the token endpoint when the token is still valid" do
    user = generate(user())

    source =
      gdrive_source(user, %{
        "access_token" => "ok",
        "refresh_token" => "r",
        "expires_at" => future_iso()
      })

    # No Bypass.expect => any HTTP call fails the test.
    assert {:ok, ^source} = TokenManager.ensure_fresh(source)
  end

  test "returns :reauth_required on invalid_grant", %{bypass: bypass} do
    user = generate(user())

    source =
      gdrive_source(user, %{
        "access_token" => "old",
        "refresh_token" => "dead",
        "expires_at" => expired_iso()
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
    end)

    assert {:error, :reauth_required} = TokenManager.ensure_fresh(source)
  end

  describe "refresh-rotation race (a concurrent winner persisted a newer token)" do
    test "adopts the winner's still-fresh token without another refresh call", %{bypass: bypass} do
      user = generate(user())

      source =
        gdrive_source(user, %{
          "access_token" => "loser-at",
          "refresh_token" => "loser-rt",
          "expires_at" => expired_iso()
        })

      # Simulate the winner: a concurrent refresh already persisted a rotated
      # token with a fresh expiry. Our in-memory `source` is now stale.
      {:ok, _} =
        Knowledge.update_source_auth_config(
          source,
          %{
            auth_config: %{
              "access_token" => "winner-at",
              "refresh_token" => "winner-rt",
              "expires_at" => future_iso()
            }
          },
          authorize?: false
        )

      # Exactly ONE token call: the loser's failed attempt. Recovery must use
      # the winner's persisted access token, not refresh again.
      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      assert {:ok, fresh} = TokenManager.ensure_fresh(source)
      assert fresh.auth_config["access_token"] == "winner-at"
      assert fresh.auth_config["refresh_token"] == "winner-rt"
    end

    test "retries the refresh with the winner's token when that one is expiring too", %{
      bypass: bypass
    } do
      user = generate(user())

      source =
        gdrive_source(user, %{
          "access_token" => "loser-at",
          "refresh_token" => "loser-rt",
          "expires_at" => expired_iso()
        })

      {:ok, _} =
        Knowledge.update_source_auth_config(
          source,
          %{
            auth_config: %{
              "access_token" => "winner-at",
              "refresh_token" => "winner-rt",
              "expires_at" => expired_iso()
            }
          },
          authorize?: false
        )

      # First call (loser-rt) fails invalid_grant; retry (winner-rt) succeeds.
      Bypass.expect(bypass, "POST", "/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        case params["refresh_token"] do
          "loser-rt" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))

          "winner-rt" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "access_token" => "recovered-at",
                "refresh_token" => "recovered-rt",
                "expires_in" => 3600
              })
            )
        end
      end)

      assert {:ok, fresh} = TokenManager.ensure_fresh(source)
      assert fresh.auth_config["access_token"] == "recovered-at"
      assert fresh.auth_config["refresh_token"] == "recovered-rt"
    end

    test "an unchanged persisted token is a real dead grant", %{bypass: bypass} do
      user = generate(user())

      source =
        gdrive_source(user, %{
          "access_token" => "old",
          "refresh_token" => "dead",
          "expires_at" => expired_iso()
        })

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_grant"}))
      end)

      assert {:error, :reauth_required} = TokenManager.ensure_fresh(source)
    end
  end

  test "non-refresh providers pass through untouched" do
    user = generate(user())

    {:ok, source} =
      Knowledge.create_source(
        %{
          name: "NC",
          provider: :nextcloud,
          auth_config: %{"base_url" => "https://x", "username" => "u", "password" => "p"}
        },
        actor: user
      )

    assert {:ok, ^source} = TokenManager.ensure_fresh(source)
  end

  test "mark_source_reauth_required flags the source and creates a notification" do
    user = generate(user())
    source = gdrive_source(user, %{"access_token" => "x", "refresh_token" => "r"})

    assert :ok = TokenManager.mark_source_reauth_required(source)

    {:ok, reloaded} = Knowledge.get_source(source.id, actor: user)
    assert reloaded.needs_reauth == true

    {:ok, notes} = Magus.Notifications.list_unread_notifications(actor: user)
    assert Enum.any?(notes, &(&1.metadata["knowledge_source_id"] == source.id))
  end
end
