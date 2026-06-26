defmodule MagusWeb.Rpc.RpcControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  alias MagusWeb.Rpc.RpcController

  describe "authentication" do
    test "run rejects unauthenticated requests", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> post("/rpc/run", %{"action" => "current_user", "fields" => ["id"]})

      assert json_response(conn, 401)
    end

    test "socket-token rejects unauthenticated requests", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/rpc/socket-token")

      assert json_response(conn, 401)
    end
  end

  describe "run current_user" do
    test "returns the authenticated actor", %{conn: conn} do
      user = generate(user())

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/json")
        |> post("/rpc/run", %{
          "action" => "current_user",
          "fields" => ["id", "email", "displayName", "uiPreferences"]
        })

      assert %{"success" => true, "data" => data} = json_response(conn, 200)
      assert data["id"] == user.id
      assert data["email"] == to_string(user.email)
    end

    test "never returns another user", %{conn: conn} do
      user = generate(user())
      _other = generate(user())

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/json")
        |> post("/rpc/run", %{"action" => "current_user", "fields" => ["id"]})

      assert %{"success" => true, "data" => %{"id" => id}} = json_response(conn, 200)
      assert id == user.id
    end
  end

  describe "run update_ui_preferences" do
    test "persists the workbench_ui toggle", %{conn: conn} do
      user = generate(user())

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/json")
        |> post("/rpc/run", %{
          "action" => "update_ui_preferences",
          "identity" => user.id,
          "input" => %{"uiPreferences" => %{"workbench_ui" => "next"}},
          "fields" => ["id", "uiPreferences"]
        })

      assert %{"success" => true} = json_response(conn, 200)

      reloaded = Magus.Accounts.get_user!(user.id, actor: user)
      assert MagusWeb.NextUi.enabled_for?(reloaded)
    end
  end

  describe "socket-token" do
    test "issues a token that UserSocket accepts", %{conn: conn} do
      user = generate(user())

      conn =
        conn
        |> log_in_user(user)
        |> put_req_header("accept", "application/json")
        |> get("/rpc/socket-token")

      assert %{"token" => token} = json_response(conn, 200)

      assert {:ok, user_id} =
               Phoenix.Token.verify(MagusWeb.Endpoint, RpcController.socket_token_salt(), token,
                 max_age: RpcController.socket_token_max_age()
               )

      assert user_id == user.id
    end
  end
end
