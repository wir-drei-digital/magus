defmodule MagusWeb.Admin.DashboardLiveTest do
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
    user
    |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:is_admin, true)
    |> Ash.update!(authorize?: false)
  end

  defp seed_usage(user, attrs) do
    defaults = %{
      user_id: user.id,
      usage_type: :response,
      model_name: "model-a",
      action_name: "chat",
      billable: true,
      total_tokens: 200,
      total_cost: Decimal.new("0.5")
    }

    Ash.Seed.seed!(Magus.Usage.MessageUsage, Map.merge(defaults, Map.new(attrs)))
  end

  test "renders all metric cards after async load", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    assert length(Floki.find(doc, "[data-test-metric-card]")) == 4
  end

  test "lists models with usage in the top-models table", %{conn: conn, admin: admin} do
    # Unique names + dominant cost so leaked rows in the shared test DB can't
    # push these out of the capped top-10.
    tag = "dash#{System.unique_integer([:positive])}"
    seed_usage(admin, model_name: "#{tag}-a", total_cost: Decimal.new("10000"))
    seed_usage(admin, model_name: "#{tag}-b", total_cost: Decimal.new("9000"))

    {:ok, view, _html} = live(conn, ~p"/admin")

    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    rows = Floki.find(doc, "[data-test-top-model]")
    assert rows != []

    row_text = rows |> Enum.map(&Floki.text/1) |> Enum.join(" ")
    assert row_text =~ "#{tag}-a"
    assert row_text =~ "#{tag}-b"
  end

  test "refresh reloads the async metrics", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    render_async(view)

    view |> element("button[phx-click=refresh]") |> render_click()
    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    assert length(Floki.find(doc, "[data-test-metric-card]")) == 4
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user())

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin")
    assert to == ~p"/"
  end
end
