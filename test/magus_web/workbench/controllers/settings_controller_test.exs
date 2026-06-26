defmodule MagusWeb.SettingsControllerTest do
  use MagusWeb.ConnCase, async: false

  import Magus.Generators

  describe "GET /settings/data/export" do
    test "returns a JSON download for authed users", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/settings/data/export")

      assert response(conn, 200)

      assert ["attachment; filename=\"magus-export-" <> _] =
               get_resp_header(conn, "content-disposition")

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      assert {:ok, decoded} = Jason.decode(conn.resp_body)
      assert decoded["schema_version"] == 1
      assert decoded["profile"]["email"] == to_string(user.email)
    end

    test "redirects unauthed users to sign-in", %{conn: conn} do
      conn = get(conn, ~p"/settings/data/export")
      assert redirected_to(conn) == "/sign-in"
    end
  end

  describe "POST /settings/data/delete" do
    test "deletes account and signs out when email matches", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      conn =
        post(conn, ~p"/settings/data/delete", %{"confirm_email" => to_string(user.email)})

      assert redirected_to(conn) == "/"

      require Ash.Query

      assert {:ok, nil} =
               Magus.Accounts.User
               |> Ash.Query.filter(id == ^user.id)
               |> Ash.read_one(authorize?: false)
    end

    test "stays on the page with flash error when email does not match", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      conn =
        post(conn, ~p"/settings/data/delete", %{"confirm_email" => "wrong@example.com"})

      assert redirected_to(conn) == "/settings/data"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not match"

      require Ash.Query

      assert {:ok, %{}} =
               Magus.Accounts.User
               |> Ash.Query.filter(id == ^user.id)
               |> Ash.read_one(authorize?: false)
    end

    test "rejects unauthenticated requests", %{conn: conn} do
      conn = post(conn, ~p"/settings/data/delete", %{"confirm_email" => "x@x"})
      assert redirected_to(conn) == "/sign-in"
    end

    test "accepts mixed-case email match (User.email is case-insensitive)", %{conn: conn} do
      user = generate(user(email: "Alice@Example.com"))
      conn = log_in_user(conn, user)

      conn =
        post(conn, ~p"/settings/data/delete", %{"confirm_email" => "alice@example.com"})

      assert redirected_to(conn) == "/"

      require Ash.Query

      assert {:ok, nil} =
               Magus.Accounts.User
               |> Ash.Query.filter(id == ^user.id)
               |> Ash.read_one(authorize?: false)
    end
  end

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
