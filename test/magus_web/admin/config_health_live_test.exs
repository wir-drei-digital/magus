defmodule MagusWeb.Admin.ConfigHealthLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  setup %{conn: conn} do
    admin = make_admin(generate(user()))

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(admin)

    %{conn: conn, admin: admin}
  end

  defp make_admin(user) do
    {:ok, admin} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:is_admin, true)
      |> Ash.update(authorize?: false)

    admin
  end

  test "renders one row per configuration check", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/config")

    {:ok, doc} = Floki.parse_document(html)
    rows = Floki.find(doc, "[data-test-config-check]")

    assert length(rows) == length(Magus.Config.Health.checks())
    assert html =~ ~s(data-test-config-check="database")
    assert html =~ ~s(data-test-config-check="sandbox")
  end

  test "tags each row with its status", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/config")

    {:ok, doc} = Floki.parse_document(html)

    statuses =
      doc
      |> Floki.find("[data-test-config-status]")
      |> Enum.map(&Floki.attribute(&1, "data-test-config-status"))
      |> List.flatten()
      |> Enum.uniq()

    assert statuses != []
    assert Enum.all?(statuses, &(&1 in ["ok", "missing", "not_configured"]))
  end

  test "surfaces the overall required-config status", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/config")
    assert html =~ "data-test-required-status="
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user(is_admin: false))

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/config")
    assert to == ~p"/"
  end
end
