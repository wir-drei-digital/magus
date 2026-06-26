defmodule MagusWeb.Rpc.AccountControllerTest do
  @moduledoc """
  Exercises the account-data controller (`/rpc/account/*`) for the SvelteKit
  settings "Data" section: deletion preflight + the email-confirmed delete.
  The heavy delete mechanics are covered by AccountDeletionTest; here we verify
  the controller wiring and the email-confirmation guard.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  test "deletion_preflight returns a deletable summary", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => data} =
             conn
             |> log_in_user(user)
             |> get("/rpc/account/deletion-preflight")
             |> json_response(200)

    assert data["canDelete"] == true
    assert is_map(data["summary"])
    assert Map.has_key?(data["summary"], "conversationCount")
  end

  test "delete with a mismatched email does not delete the account", %{conn: conn} do
    user = generate(user())

    assert %{"success" => false} =
             conn
             |> log_in_user(user)
             |> put_req_header("content-type", "application/json")
             |> post("/rpc/account/delete", %{"confirmEmail" => "wrong@example.com"})
             |> json_response(200)

    assert {:ok, _still_here} = Magus.Accounts.get_user(user.id, authorize?: false)
  end

  test "delete with the matching email hard-deletes the account", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => %{"deleted" => true}} =
             conn
             |> log_in_user(user)
             |> put_req_header("content-type", "application/json")
             |> post("/rpc/account/delete", %{"confirmEmail" => to_string(user.email)})
             |> json_response(200)

    assert {:error, _gone} = Magus.Accounts.get_user(user.id, authorize?: false)
  end

  test "unauthenticated preflight is rejected", %{conn: conn} do
    conn = get(conn, "/rpc/account/deletion-preflight")
    assert conn.status in [401, 302]
  end
end
