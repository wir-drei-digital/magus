defmodule MagusWeb.Workbench.SignalsTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Workbench.Signals

  test "tab_topic/1 returns the expected topic string" do
    assert Signals.tab_topic("tab_abc") == "workbench:tab:tab_abc"
  end

  describe "broadcast_open_companion/2" do
    test "publishes on the tab topic" do
      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench:tab:tab_xyz")

      Signals.broadcast_open_companion("tab_xyz", %{
        "type" => "draft",
        "id" => "draft_123"
      })

      assert_receive {:workbench_companion, {:open, %{"type" => "draft", "id" => "draft_123"}}}
    end
  end

  describe "broadcast_close_companion/1" do
    test "publishes on the tab topic" do
      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench:tab:tab_xyz")

      Signals.broadcast_close_companion("tab_xyz")

      assert_receive {:workbench_companion, :close}
    end
  end

  test "broadcast_pdf_selection sends a workbench_chrome message to the tab topic" do
    tab_id = "tab_test_#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Magus.PubSub, Signals.tab_topic(tab_id))

    payload = %{"text" => "selected", "image" => "data:image/png;base64,xxx", "page" => 3}
    :ok = Signals.broadcast_pdf_selection(tab_id, payload)

    assert_receive {:workbench_chrome, {:pdf_selection, ^payload}}, 200
  end
end
