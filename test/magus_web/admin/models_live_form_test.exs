defmodule MagusWeb.Admin.ModelsLiveFormTest do
  use MagusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias AshAuthentication.Plug.Helpers
  alias Magus.Chat.Model

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

  defp created_model!(key) do
    require Ash.Query

    Model
    |> Ash.Query.filter(key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  describe "description translations" do
    test "both language inputs stay in the DOM across tab switches", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/models/new")

      # Both locales must be present as form inputs regardless of which tab
      # is active, otherwise submitting wipes the hidden language.
      assert html =~ ~s(name="form[short_description_translations][en]")
      assert html =~ ~s(name="form[short_description_translations][de]")

      html = view |> element("button[phx-value-tab=de]") |> render_click()

      assert html =~ ~s(name="form[short_description_translations][en]")
      assert html =~ ~s(name="form[short_description_translations][de]")
    end

    test "saving after switching tabs keeps both languages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

      # Type the English text, then switch to the German tab (this is the
      # user flow that previously wiped English on save).
      view
      |> element("form[phx-submit=save]")
      |> render_change(%{
        "form" => %{
          "name" => "Trans Model",
          "key" => "openrouter:test/trans-model",
          "short_description_translations" => %{"en" => "English blurb"}
        }
      })

      view |> element("button[phx-value-tab=de]") |> render_click()

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "short_description_translations" => %{"de" => "Deutscher Text"}
        }
      })

      model = created_model!("openrouter:test/trans-model")
      assert model.short_description_translations["en"] == "English blurb"
      assert model.short_description_translations["de"] == "Deutscher Text"
    end

    test "the English translation mirrors into the raw description fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "name" => "Mirror Model",
          "key" => "openrouter:test/mirror-model",
          "short_description_translations" => %{"en" => "Short EN", "de" => "Kurz DE"},
          "detailed_description_translations" => %{"en" => "Long EN", "de" => ""}
        }
      })

      # The SPA reads the raw (untranslated) description attributes, so the
      # English text must land there too or admin-entered descriptions never
      # reach the model picker.
      model = created_model!("openrouter:test/mirror-model")
      assert model.short_description == "Short EN"
      assert model.detailed_description == "Long EN"
    end
  end

  describe "pricing" do
    test "plain-number costs persist as structured values plus display strings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "name" => "Cost Model",
          "key" => "openrouter:test/cost-model",
          "input_cost_value" => "2.5",
          "output_cost_value" => "10"
        }
      })

      model = created_model!("openrouter:test/cost-model")
      assert Decimal.equal?(model.input_cost_value, Decimal.new("2.5"))
      assert Decimal.equal?(model.output_cost_value, Decimal.new("10"))
      assert model.input_cost_unit == :per_million_tokens

      # The legacy display strings mirror the entered numbers so existing
      # consumers (admin table, model picker) keep rendering a value.
      assert model.input_cost == "2.5"
      assert model.output_cost == "10"
    end
  end

  describe "model key" do
    test "a key without an api prefix gets openrouter: prepended on save", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "name" => "Prefix Model",
          "key" => "anthropic/claude-test"
        }
      })

      assert created_model!("openrouter:anthropic/claude-test")
    end

    test "an explicit api prefix is preserved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/models/new")

      view
      |> element("form[phx-submit=save]")
      |> render_submit(%{
        "form" => %{
          "name" => "XAI Model",
          "key" => "xai:grok-test"
        }
      })

      assert created_model!("xai:grok-test")
    end
  end

  describe "denied providers" do
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
end
