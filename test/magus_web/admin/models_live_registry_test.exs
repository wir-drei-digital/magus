defmodule MagusWeb.Admin.ModelsLiveRegistryTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  setup %{conn: conn} do
    # Seeded providers/internal models from the InternalizeExtras data
    # migration live in the base test connection. Clear the catalog so tests
    # start from a known-empty provider/model set.
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

  # Release dates rendered per row, in DOM order, blanks dropped.
  defp registry_dates(html) do
    ~r/data-test-registry-date="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
    |> Enum.reject(&(&1 == ""))
  end

  test "registry picker lists LLMDB models for a provider and prefills the form",
       %{conn: conn} do
    provider =
      Magus.Models.create_provider!(
        %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/admin/models/from-registry")

    # Step 1: pick the provider.
    html =
      view
      |> element(~s(form[phx-change="select_registry_provider"]))
      |> render_change(%{"provider_id" => provider.id})

    # Step 2: registry models are listed.
    assert html =~ "data-test-registry-model"

    # Pick the FIRST rendered registry entry rather than a hardcoded id, so a
    # future LLMDB snapshot bump that drops/renames a model can't break this
    # test for unrelated reasons.
    [_, registry_id] = Regex.run(~r/data-test-registry-model="([^"]+)"/, html)

    # Step 3: selecting an entry switches to the create form, prefilled.
    form_html =
      view
      |> element(~s([data-test-registry-model="#{registry_id}"]))
      |> render_click()

    # The create form is now rendered with the key prefilled as
    # "<slug>:<registry_id>".
    assert form_html =~ "openrouter:#{registry_id}"
    assert render(view) =~ ~s(value="openrouter:#{registry_id}")
  end

  test "delete shows reference counts and survives FK restriction", %{conn: conn} do
    model = generate(model())
    _slot = routing_slot(model_id: model.id, specialty: :coding, tier: :complex)

    {:ok, view, _html} = live(conn, ~p"/admin/models")

    # Open the delete-confirm flow for this model.
    html =
      view
      |> element(~s([data-test-delete-confirm="#{model.id}"]))
      |> render_click()

    assert html =~ "data-test-references"

    # Attempting the delete must not crash (FK restricts) and the model
    # must still exist.
    view
    |> element(~s([data-test-delete="#{model.id}"]))
    |> render_click()

    assert render(view) =~ "data-test-models-table"
    assert {:ok, _still_there} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
  end

  test "internal models show in the admin list with a badge", %{conn: conn} do
    model = generate(model(internal?: true, name: "Internal Util"))

    {:ok, _view, html} = live(conn, ~p"/admin/models")

    assert html =~ ~s(data-test-internal-badge="#{model.key}")
  end

  test "registry vendor filter narrows an aggregator's models to one vendor",
       %{conn: conn} do
    provider =
      Magus.Models.create_provider!(
        %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/admin/models/from-registry")

    html =
      view
      |> element(~s(form[phx-change="select_registry_provider"]))
      |> render_change(%{"provider_id" => provider.id})

    # OpenRouter aggregates many vendors, so the vendor sub-filter is shown.
    assert html =~ "data-test-registry-vendor"

    # Derive a real vendor from the first listed "vendor/model" id, so a future
    # LLMDB snapshot bump can't break this for unrelated reasons.
    [_, first_id] = Regex.run(~r/data-test-registry-model="([^"]+)"/, html)
    vendor = first_id |> String.split("/", parts: 2) |> hd()

    filtered =
      view
      |> element(~s(form[phx-change="filter_registry"]))
      |> render_change(%{"filter" => "", "vendor" => vendor})

    ids =
      ~r/data-test-registry-model="([^"]+)"/
      |> Regex.scan(filtered)
      |> Enum.map(&List.last/1)

    assert ids != []
    assert Enum.all?(ids, &String.starts_with?(&1, vendor <> "/"))
  end

  test "registry has a sortable 'Date added' column", %{conn: conn} do
    provider =
      Magus.Models.create_provider!(
        %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
        authorize?: false
      )

    {:ok, view, _html} = live(conn, ~p"/admin/models/from-registry")

    html =
      view
      |> element(~s(form[phx-change="select_registry_provider"]))
      |> render_change(%{"provider_id" => provider.id})

    assert html =~ "Date added"
    assert html =~ "data-test-registry-sort-date"

    # First click sorts ascending by release_date.
    asc = view |> element(~s([data-test-registry-sort-date])) |> render_click()
    asc_dates = registry_dates(asc)
    assert asc_dates != []
    assert asc_dates == Enum.sort(asc_dates)

    # Second click flips to descending.
    desc = view |> element(~s([data-test-registry-sort-date])) |> render_click()
    desc_dates = registry_dates(desc)
    assert desc_dates != []
    assert desc_dates == Enum.sort(desc_dates, :desc)
  end

  test "non-admin user cannot access the registry picker", %{conn: _conn} do
    non_admin = generate(user(is_admin: false))

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Helpers.store_in_session(non_admin)

    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/models/from-registry")
    assert to == ~p"/"
  end
end
