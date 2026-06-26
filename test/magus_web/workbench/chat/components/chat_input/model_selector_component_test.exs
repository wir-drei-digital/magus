defmodule MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponentTest do
  use MagusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent

  # Minimal model-like map carrying the fields the picker renders. Using plain
  # maps keeps this a fast unit test that does not touch the DB.
  defp model(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        key: "test/model-#{System.unique_integer([:positive])}",
        name: "Test Model",
        provider: "test",
        input_cost: "$2/M",
        output_cost: "$12/M",
        input_cost_value: Decimal.new("2"),
        output_cost_value: Decimal.new("12"),
        input_cost_unit: :per_million_tokens,
        output_cost_unit: :per_million_tokens,
        input_modalities: ["text"],
        output_modalities: ["text"],
        supports_search?: false,
        supports_reasoning?: false,
        context_window: 128_000,
        short_description: nil,
        short_description_translations: nil
      },
      Map.new(attrs)
    )
  end

  defp render_picker(models) do
    render_component(ModelSelectorComponent,
      id: "model-selector-test",
      models: models,
      selected_model_id: nil,
      chat_mode: :chat,
      current_user: nil,
      conversation: nil
    )
  end

  test "color-codes each model's per-request cost by tier (structural hook)" do
    cheap =
      model(
        key: "test/cheap",
        input_cost_value: Decimal.new("0.2"),
        output_cost_value: Decimal.new("0.5")
      )

    pricey =
      model(
        key: "test/pricey",
        input_cost_value: Decimal.new("75"),
        output_cost_value: Decimal.new("150")
      )

    html = render_picker([cheap, pricey])

    # Each model row exposes a cost hook keyed by model.key, color-coded by a
    # cost tier. Assert the tier (structural), not the rendered CHF amount.
    assert html =~ ~s(data-test-model-cost="test/cheap")
    assert html =~ ~s(data-test-model-cost="test/pricey")
    assert html =~ ~s(data-test-model-cost-tier="cheap")
    assert html =~ ~s(data-test-model-cost-tier="expensive")

    # Raw per-M input/output cost is also surfaced in the footer.
    assert html =~ ~s(data-test-model-cost-permillion="test/cheap")
    assert html =~ ~s(data-test-model-cost-permillion="test/pricey")
  end

  test "does not disable any model by cost" do
    pricey = model(key: "test/pricey", input_cost: "$999/M", output_cost: "$999/M")

    html = render_picker([pricey])

    # No model button is rendered disabled (cost gating removed).
    refute html =~ "disabled"
    refute html =~ "cursor-not-allowed"
  end
end
