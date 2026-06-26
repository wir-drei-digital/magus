defmodule MagusWeb.Workbench.ContextIndicatorTest do
  use MagusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MagusWeb.ChatLive.Components.ChatInput.ContextIndicatorComponent

  # The component reads the context-window snapshot via `field/2` (= `Map.get/2`),
  # so a plain map with the keys `update/2` touches is enough for a fast unit test
  # that does not hit the DB.
  defp snapshot(attrs) do
    Map.merge(
      %{
        last_total_tokens: 50_000,
        last_max_context: 100_000,
        last_model_key: "old/model",
        compaction_status: :idle,
        last_breakdown: nil,
        last_cached_tokens: nil,
        strategy: nil
      },
      attrs
    )
  end

  test "uses the selected model's context window for the fill" do
    cw = snapshot(%{last_model_key: "old/model"})
    model = %{context_window: 200_000}

    html = render_component(ContextIndicatorComponent, id: "d", context_window: cw, model: model)

    # 50_000 / 200_000 = 0.25: the selected model's window wins over the
    # persisted last_max_context (which would give 0.5).
    assert html =~ ~s(data-context-fill="0.25")
    # No attribution line when a concrete model is selected.
    refute html =~ ~s(data-role="context-model")
  end

  test "auto mode falls back to last_max_context and shows attribution" do
    cw = snapshot(%{last_model_key: "auto/picked"})

    html = render_component(ContextIndicatorComponent, id: "d", context_window: cw, model: nil)

    # 50_000 / 100_000 = 0.5: no model selected, so the persisted window is used.
    assert html =~ ~s(data-context-fill="0.5")
    assert html =~ ~s(data-role="context-model")
  end

  # 3a: a lost-update race exists if Clear can fire mid-compaction (the in-flight
  # pass clobbers the new floor). The Clear button must carry `disabled` while a
  # compaction is in flight, mirroring the Compact button.
  test "disables the Clear button while compaction is running (owner)" do
    cw = snapshot(%{compaction_status: :running})

    html =
      render_component(ContextIndicatorComponent,
        id: "d",
        context_window: cw,
        model: nil,
        is_owner: true
      )

    [clear_btn] = Floki.find(Floki.parse_fragment!(html), ~s([data-role="context-clear"]))
    assert Floki.attribute(clear_btn, "disabled") != []
  end

  # 3b: a model whose `context_window` is literally 0 must not become a /0
  # denominator (0 is truthy in Elixir). Fall back to last_max_context.
  test "guards a context_window == 0 model and falls back to last_max_context" do
    cw = snapshot(%{last_max_context: 100_000})
    model = %{context_window: 0}

    html =
      render_component(ContextIndicatorComponent, id: "d", context_window: cw, model: model)

    # 50_000 / 100_000 = 0.5: the 0-window model is ignored, last_max_context wins
    # (a 0 denominator would give data-context-fill="0.0").
    assert html =~ ~s(data-context-fill="0.5")
  end
end
