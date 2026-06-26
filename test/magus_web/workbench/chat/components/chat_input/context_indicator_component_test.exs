defmodule MagusWeb.ChatLive.Components.ChatInput.ContextIndicatorComponentTest do
  use MagusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MagusWeb.ChatLive.Components.ChatInput.ContextIndicatorComponent

  # The component reads the persisted snapshot via Map.get, so a plain map with
  # the same fields stands in for a Magus.Chat.ContextWindow struct. Breakdown
  # uses STRING keys, mirroring the persisted JSON shape.
  defp render_donut(opts) do
    render_component(
      ContextIndicatorComponent,
      Keyword.merge(
        [
          id: "context-donut-test",
          context_window: nil,
          model: nil,
          # The control-row tests below exercise the owner view; default to owner
          # so they render the Clear/Compact/strategy buttons. The owner-gating
          # tests pass is_owner explicitly.
          is_owner: true
        ],
        opts
      )
    )
  end

  test "renders a filled donut + breakdown panel from a context_window snapshot" do
    cw = %{
      last_total_tokens: 64_000,
      last_max_context: 128_000,
      last_breakdown: %{
        "categories" => [
          %{"key" => "tools", "label" => "Tools", "tokens" => 100},
          %{"key" => "history", "label" => "History", "tokens" => 63_900}
        ]
      }
    }

    html = render_donut(context_window: cw)

    # Donut root + fill hook (64000 / 128000 = 0.5).
    assert html =~ ~s(data-role="context-donut")
    assert html =~ ~s(data-context-fill="0.5")

    # Total line surfaces tokens used / max (compact-formatted).
    assert html =~ ~s(data-role="context-total")
    assert html =~ "64.0K"
    assert html =~ "128.0K"

    # Breakdown panel lists each category label + token count.
    assert html =~ ~s(data-role="context-breakdown")
    assert html =~ "Tools"
    assert html =~ "100"
    assert html =~ "History"
  end

  test "renders a cached-tokens line when last_cached_tokens is positive" do
    cw = %{
      last_total_tokens: 1000,
      last_max_context: 128_000,
      last_cached_tokens: 400
    }

    html = render_donut(context_window: cw)

    assert html =~ ~s(data-role="context-cached")
    assert html =~ "400"
    # 400 / 1000 = 40% of total input tokens.
    assert html =~ "40%"
  end

  test "omits the cached-tokens line when last_cached_tokens is nil or 0" do
    nil_cached = render_donut(context_window: %{last_total_tokens: 1000, last_cached_tokens: nil})
    refute nil_cached =~ ~s(data-role="context-cached")

    zero_cached = render_donut(context_window: %{last_total_tokens: 1000, last_cached_tokens: 0})
    refute zero_cached =~ ~s(data-role="context-cached")
  end

  test "renders a 0% donut without crashing when context_window is nil" do
    html = render_donut(context_window: nil)

    assert html =~ ~s(data-role="context-donut")
    assert html =~ ~s(data-context-fill="0.0")
    assert html =~ ~s(data-role="context-breakdown")
  end

  test "falls back to the model context_window when no snapshot max is present" do
    # No last_max_context on the snapshot; the model window (200k) is used as the
    # denominator. 50000 / 200000 = 0.25.
    cw = %{last_total_tokens: 50_000, last_max_context: nil, last_breakdown: nil}
    model = %{context_window: 200_000}

    html = render_donut(context_window: cw, model: model)

    assert html =~ ~s(data-context-fill="0.25")
  end

  describe "owner-gated control row" do
    test "owner sees the strategy / compact / clear controls" do
      html = render_donut(is_owner: true)

      assert html =~ ~s(data-role="context-strategy-rolling")
      assert html =~ ~s(data-role="context-strategy-compact")
      assert html =~ ~s(data-role="context-compact")
      assert html =~ ~s(data-role="context-clear")
    end

    test "non-owner sees the read-only donut but no control row" do
      html = render_donut(is_owner: false)

      # Donut gauge + breakdown still render read-only.
      assert html =~ ~s(data-role="context-donut")
      assert html =~ ~s(data-role="context-breakdown")

      # The Clear / Compact / strategy controls are hidden.
      refute html =~ ~s(data-role="context-strategy-rolling")
      refute html =~ ~s(data-role="context-strategy-compact")
      refute html =~ ~s(data-role="context-compact")
      refute html =~ ~s(data-role="context-clear")
    end

    test "control row is hidden when is_owner is omitted (defaults to false)" do
      html =
        render_component(
          ContextIndicatorComponent,
          id: "context-donut-test",
          context_window: nil,
          model: nil
        )

      assert html =~ ~s(data-role="context-donut")
      refute html =~ ~s(data-role="context-clear")
    end
  end

  describe "compact button" do
    test "renders enabled when status is :idle" do
      html = render_donut(context_window: %{compaction_status: :idle})

      assert html =~ ~s(data-role="context-compact")
      assert html =~ ~s(data-compaction-status="idle")
      # Enabled: no disabled attribute on the compact button.
      refute compact_button_disabled?(html)
    end

    test "renders enabled when context_window is nil (defaults to :idle)" do
      html = render_donut(context_window: nil)

      assert html =~ ~s(data-role="context-compact")
      assert html =~ ~s(data-compaction-status="idle")
      refute compact_button_disabled?(html)
    end

    test "renders disabled while compaction is :pending" do
      html = render_donut(context_window: %{compaction_status: :pending})

      assert html =~ ~s(data-compaction-status="pending")
      assert compact_button_disabled?(html)
    end

    test "renders disabled while compaction is :running" do
      html = render_donut(context_window: %{compaction_status: :running})

      assert html =~ ~s(data-compaction-status="running")
      assert compact_button_disabled?(html)
    end

    test "stays enabled when compaction :failed (acts as retry)" do
      html = render_donut(context_window: %{compaction_status: :failed})

      assert html =~ ~s(data-compaction-status="failed")
      refute compact_button_disabled?(html)
    end
  end

  # The compact button is the only element carrying data-role="context-compact".
  # It is disabled iff a `disabled` attribute is rendered before the next tag.
  defp compact_button_disabled?(html) do
    case Regex.run(~r/data-role="context-compact"(.*?)>/s, html) do
      [_, attrs] -> attrs =~ "disabled"
      _ -> false
    end
  end
end
