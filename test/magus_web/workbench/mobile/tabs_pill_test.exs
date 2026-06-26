defmodule MagusWeb.Workbench.Mobile.TabsPillTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias MagusWeb.Workbench.Mobile.TabsPill

  defp tab(id, type, label) do
    %{
      "id" => id,
      "primary" => %{"type" => type, "id" => "x"},
      "label" => label,
      "companion" => nil
    }
  end

  test "renders nothing when there are no tabs" do
    html =
      render_component(TabsPill,
        id: "tp",
        tabs: [],
        active_tab_id: nil,
        open?: false
      )

    refute html =~ ~s(data-tabs-pill-trigger)
  end

  test "renders trigger when tabs exist" do
    tabs = [tab("t1", "conversation", "First"), tab("t2", "conversation", "Second")]

    html =
      render_component(TabsPill,
        id: "tp",
        tabs: tabs,
        active_tab_id: "t1",
        open?: false
      )

    assert html =~ ~s(data-tabs-pill-trigger)
  end

  test "popover is hidden when open? is false" do
    tabs = [tab("t1", "conversation", "First")]

    html =
      render_component(TabsPill,
        id: "tp",
        tabs: tabs,
        active_tab_id: "t1",
        open?: false
      )

    refute html =~ ~s(data-tabs-pill-popover)
  end

  test "popover renders all tabs and a New chat footer when open" do
    tabs = [tab("t1", "conversation", "First"), tab("t2", "brain_page", "Notes")]

    html =
      render_component(TabsPill,
        id: "tp",
        tabs: tabs,
        active_tab_id: "t1",
        open?: true
      )

    assert html =~ ~s(data-tabs-pill-popover)
    assert html =~ ~s(data-pill-tab="t1")
    assert html =~ ~s(data-pill-tab="t2")
    assert html =~ ~s(data-pill-tab-active="t1")
    assert html =~ ~s(data-pill-close-tab="t1")
    assert html =~ ~s(data-pill-close-tab="t2")
    assert html =~ ~s(data-pill-new-chat)
  end

  test "trigger fires toggle_tabs_pill, rows fire activate_tab" do
    tabs = [tab("t1", "conversation", "First")]

    html =
      render_component(TabsPill,
        id: "tp",
        tabs: tabs,
        active_tab_id: "t1",
        open?: true
      )

    assert html =~ ~s(phx-click="toggle_tabs_pill")
    assert html =~ ~s(phx-click="activate_tab")
    assert html =~ ~s(phx-click="close_tab")
    assert html =~ ~s(phx-click="new_tab")
  end
end
