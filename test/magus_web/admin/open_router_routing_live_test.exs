defmodule MagusWeb.Admin.OpenRouterRoutingLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers
  alias Magus.Models

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

  test "lists provider rows, mode banner, and sync button", %{conn: conn} do
    {:ok, _} =
      Models.upsert_open_router_provider(%{slug: "anthropic", name: "Anthropic"},
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/admin/openrouter-routing")

    assert has_element?(view, ~s([data-testid="or-provider-row"]))
    assert has_element?(view, ~s([data-testid="or-mode-banner"]))
    assert html =~ "or-sync-button"
  end

  test "toggling allow flips the stored flag", %{conn: conn} do
    {:ok, _} =
      Models.upsert_open_router_provider(%{slug: "acme", name: "Acme"}, authorize?: false)

    {:ok, view, _} = live(conn, ~p"/admin/openrouter-routing")

    refute Models.get_open_router_provider_by_slug!("acme", authorize?: false).allowed

    view
    |> element(~s([data-testid="or-allow-toggle-acme"]))
    |> render_click()

    assert Models.get_open_router_provider_by_slug!("acme", authorize?: false).allowed
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user(is_admin: false))

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/openrouter-routing")
    assert to == ~p"/"
  end
end
