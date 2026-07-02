defmodule MagusWeb.Admin.UsageLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  # The shared test DB can contain committed leftover usage rows from
  # live/build runs, so tests scope to their own rows via a unique model name
  # pinned through the ?model= filter param.
  setup %{conn: conn} do
    admin = make_admin(generate(user()))

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(admin)

    %{conn: conn, admin: admin, tag: "usage#{System.unique_integer([:positive])}"}
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

  test "renders summary and all charts after async load", %{conn: conn, admin: admin, tag: tag} do
    seed_usage(admin, model_name: tag)

    {:ok, view, _html} = live(conn, ~p"/admin/usage?model=#{tag}")
    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    assert Floki.find(doc, "[data-test-usage-summary]") != []

    for id <- [
          "billable-chart",
          "action-chart",
          "model-scatter-chart",
          "cost-action-chart",
          "token-histogram",
          "finish-reason-chart"
        ] do
      assert [_] = Floki.find(doc, "canvas##{id}"), "missing chart canvas #{id}"
    end
  end

  test "top users table has one row per user with usage", %{
    conn: conn,
    admin: admin,
    tag: tag
  } do
    other = generate(user())
    seed_usage(admin, model_name: tag)
    seed_usage(other, model_name: tag)

    {:ok, view, _html} = live(conn, ~p"/admin/usage?model=#{tag}")
    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    assert length(Floki.find(doc, "[data-test-top-users] tbody tr")) == 2
  end

  test "changing filters patches the URL and reloads", %{conn: conn, admin: admin, tag: tag} do
    seed_usage(admin, model_name: tag)

    {:ok, view, _html} = live(conn, ~p"/admin/usage")
    render_async(view)

    view
    |> element("form[phx-change=filter]")
    |> render_change(%{time_range: "7d", model: ""})

    path = assert_patch(view)
    assert path =~ "range=7d"

    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)
    assert Floki.find(doc, "[data-test-usage-summary]") != []
  end

  test "sorting the top-users table does not crash", %{conn: conn, admin: admin, tag: tag} do
    seed_usage(admin, model_name: tag)

    {:ok, view, _html} = live(conn, ~p"/admin/usage?model=#{tag}")
    render_async(view)

    view |> element("th[phx-value-by=requests]") |> render_click()
    html = render_async(view)
    {:ok, doc} = Floki.parse_document(html)

    assert length(Floki.find(doc, "[data-test-top-users] tbody tr")) == 1
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user())

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/usage")
    assert to == ~p"/"
  end
end
