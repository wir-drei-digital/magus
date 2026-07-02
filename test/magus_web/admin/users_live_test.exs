defmodule MagusWeb.Admin.UsersLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  # The shared test DB can contain committed leftover users from live/build
  # runs, so each test scopes the table to its own users via a unique email
  # prefix driven through the ?q= search param.
  setup %{conn: conn} do
    tag = "ulive#{System.unique_integer([:positive])}"
    admin = make_admin(generate(user(email: "#{tag}-admin@test.com")))

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(admin)

    %{conn: conn, admin: admin, tag: tag}
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
      billable: true,
      total_tokens: 200,
      total_cost: Decimal.new("0.5")
    }

    Ash.Seed.seed!(Magus.Usage.MessageUsage, Map.merge(defaults, Map.new(attrs)))
  end

  defp row_ids(html) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find("[data-test-user-row]")
    |> Enum.flat_map(&Floki.attribute(&1, "data-test-user-row"))
  end

  test "renders one row per user after async load", %{conn: conn, tag: tag} do
    _other = generate(user(email: "#{tag}-other@test.com"))

    {:ok, view, _html} = live(conn, ~p"/admin/users?q=#{tag}")
    html = render_async(view)

    # admin + other
    assert length(row_ids(html)) == 2
  end

  test "sorting by a usage column patches the URL and reorders rows", %{
    conn: conn,
    admin: admin,
    tag: tag
  } do
    heavy = generate(user(email: "#{tag}-heavy@test.com"))
    seed_usage(heavy, total_cost: Decimal.new("9.0"))
    seed_usage(admin, total_cost: Decimal.new("1.0"))

    {:ok, view, _html} = live(conn, ~p"/admin/users?q=#{tag}")
    render_async(view)

    # First click sorts ascending: cheapest user first.
    view |> element("[data-test-sort=total_cost]") |> render_click()
    assert_patch(view)
    assert row_ids(render_async(view)) == [admin.id, heavy.id]

    # Second click flips to descending.
    view |> element("[data-test-sort=total_cost]") |> render_click()
    assert_patch(view)
    assert row_ids(render_async(view)) == [heavy.id, admin.id]
  end

  test "search narrows the rows and lands in the URL", %{conn: conn, tag: tag} do
    target = generate(user(email: "#{tag}-target@test.com"))

    {:ok, view, _html} = live(conn, ~p"/admin/users")
    render_async(view)

    view
    |> element("form[phx-change=search]")
    |> render_change(%{query: to_string(target.email)})

    path = assert_patch(view)
    assert path =~ "q="
    assert row_ids(render_async(view)) == [target.id]
  end

  test "list state is restored from the URL", %{conn: conn, admin: admin, tag: tag} do
    heavy = generate(user(email: "#{tag}-heavy@test.com"))
    seed_usage(heavy, [])

    {:ok, view, _html} = live(conn, ~p"/admin/users?q=#{tag}&sort=message_count&dir=desc")

    assert row_ids(render_async(view)) == [heavy.id, admin.id]
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user())

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/users")
    assert to == ~p"/"
  end
end
