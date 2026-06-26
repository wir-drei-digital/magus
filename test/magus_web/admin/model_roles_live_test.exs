defmodule MagusWeb.Admin.ModelRolesLiveTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers
  alias Magus.Models.Roles

  setup %{conn: conn} do
    # Seeded catalog rows (providers/models) live in the base test connection.
    # Clear so role resolution falls through to config/code defaults and the
    # model-select options start empty.
    Magus.DataCase.clear_catalog!()

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

  # A text-output chat model an admin could assign to a chat role.
  defp text_model(key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "Text #{key}",
      key: key,
      provider: "openrouter",
      active?: true,
      output_modalities: ["text"]
    })
    |> Ash.create!(authorize?: false)
  end

  test "lists every registry role with its resolution source", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/models/roles")

    for role <- Roles.all() do
      assert html =~ ~s(data-test-role="#{role.key}")
    end

    assert html =~ "data-test-embedding-warning"
  end

  test "assigning a model updates resolution", %{conn: conn} do
    model = text_model("openrouter:test/summary-model")

    {:ok, view, _html} = live(conn, ~p"/admin/models/roles")

    view
    |> element(~s([data-test-role-form="summary"]))
    |> render_change(%{"role" => "summary", "model_id" => model.id})

    assert Roles.resolve(:summary) == model.key
  end

  test "disable toggle only exists for nilable roles and works", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/models/roles")

    assert html =~ ~s(data-test-disable-role="intent_classification")
    refute html =~ ~s(data-test-disable-role="summary")

    view
    |> element(~s([data-test-disable-role="intent_classification"]))
    |> render_click()

    # A DB assignment was created with disabled? true (config already resolves
    # nil in test env, so assert the persisted row rather than resolution only).
    assert {:ok, assignment} = Magus.Models.get_role_assignment("intent_classification")
    assert assignment.disabled? == true
    assert Roles.resolve(:intent_classification) == nil
  end

  test "reset returns an assigned role to its default", %{conn: conn} do
    model = text_model("openrouter:test/super-brain-model")
    default = Roles.get!(:super_brain_extraction).default

    {:ok, view, _html} = live(conn, ~p"/admin/models/roles")

    # Assign first so a DB row exists and a Reset button renders.
    view
    |> element(~s([data-test-role-form="super_brain_extraction"]))
    |> render_change(%{"role" => "super_brain_extraction", "model_id" => model.id})

    assert Roles.resolve(:super_brain_extraction) == model.key

    view
    |> element(~s([data-test-reset-role="super_brain_extraction"]))
    |> render_click()

    assert {:error, _} = Magus.Models.get_role_assignment("super_brain_extraction")
    assert Roles.resolve(:super_brain_extraction) == default
  end

  test "reset button only renders for roles with a real DB assignment", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/models/roles")

    # intent_classification resolves to nil via config (classification_model: nil
    # in test env) with NO DB assignment row, so no Reset button should render.
    refute html =~ ~s(data-test-reset-role="intent_classification")

    # Disabling creates a DB assignment row, after which Reset appears.
    html =
      view
      |> element(~s([data-test-disable-role="intent_classification"]))
      |> render_click()

    assert html =~ ~s(data-test-reset-role="intent_classification")
  end

  test "non-admin user cannot access", %{conn: _conn} do
    non_admin = generate(user(is_admin: false))

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/models/roles")
    assert to == ~p"/"
  end
end
