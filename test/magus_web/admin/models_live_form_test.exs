defmodule MagusWeb.Admin.ModelsLiveFormTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers

  setup %{conn: conn} do
    # Seeded providers/internal models live in the base test connection; start
    # from a known-empty catalog so the rendered form is deterministic.
    Magus.DataCase.clear_catalog!()
    # The OpenRouter provider catalog is separate from `clear_catalog!/0`; clear
    # any leaked rows so only the providers this test seeds render as checkboxes.
    Magus.Repo.delete_all(Magus.Models.OpenRouterProvider)

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

  defp create_model do
    Ash.create!(
      Magus.Chat.Model,
      %{name: "T", key: "openrouter:test/t", provider: "test", api_provider: :openrouter},
      action: :create,
      authorize?: false
    )
  end

  test "edit form persists selected denied_providers", %{conn: conn} do
    Magus.Models.upsert_open_router_provider(
      %{slug: "deepseek", name: "DeepSeek"},
      authorize?: false
    )

    model = create_model()

    {:ok, view, html} = live(conn, ~p"/admin/models/#{model.id}/edit")

    # The synced provider slug renders as a denied_providers checkbox.
    assert html =~ ~s(name="form[denied_providers][]")

    view
    |> form("#model-form", form: %{denied_providers: ["deepseek"]})
    |> render_submit()

    assert "deepseek" in Magus.Chat.get_model!(model.id, authorize?: false).denied_providers
  end

  test "unchecking all denied_providers clears the list back to []", %{conn: conn} do
    Magus.Models.upsert_open_router_provider(
      %{slug: "deepseek", name: "DeepSeek"},
      authorize?: false
    )

    model =
      Ash.create!(
        Magus.Chat.Model,
        %{
          name: "T",
          key: "openrouter:test/t",
          provider: "test",
          api_provider: :openrouter,
          denied_providers: ["deepseek"]
        },
        action: :create,
        authorize?: false
      )

    {:ok, view, html} = live(conn, ~p"/admin/models/#{model.id}/edit")

    # The hidden sentinel guarantees the key is still sent when every checkbox is
    # unchecked, so the browser cannot silently omit denied_providers.
    assert html =~ ~s(type="hidden" name="form[denied_providers][]")

    # Submitting the sentinel alone mirrors an all-unchecked browser submit; the
    # NormalizeDeniedProviders change strips the blank entry so [""] persists as [].
    view
    |> form("#model-form", form: %{denied_providers: [""]})
    |> render_submit()

    assert Magus.Chat.get_model!(model.id, authorize?: false).denied_providers == []
  end

  test "denied_providers section shows a hint when no providers are synced", %{conn: conn} do
    model = create_model()

    {:ok, _view, html} = live(conn, ~p"/admin/models/#{model.id}/edit")

    refute html =~ ~s(name="form[denied_providers][]")
    assert html =~ "Sync OpenRouter providers first"
  end
end
