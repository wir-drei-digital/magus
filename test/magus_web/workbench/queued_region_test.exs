defmodule MagusWeb.Workbench.QueuedRegionTest do
  # Pure presentational function component: no DB/conn/Mox needed, so a plain
  # async ExUnit case (not MagusWeb.LiveViewCase, which forces Mox global mode).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MagusWeb.ChatLive.UI.ChatComponents

  test "renders one row per queued message with send-now and remove controls" do
    html =
      render_component(&ChatComponents.queued_messages_region/1, %{
        messages: [%{id: "m1", text: "first"}, %{id: "m2", text: "second"}]
      })

    rows = html |> Floki.parse_fragment!() |> Floki.find("[data-queued-message]")

    assert length(rows) == 2
    assert html =~ "send_now_queued"
    assert html =~ "remove_queued"
    assert html =~ "first"
    assert html =~ "second"
    assert html =~ ~s(data-queued-id="m1")
    assert html =~ ~s(phx-value-id="m2")
  end

  test "handles string-keyed payloads from PubSub" do
    html =
      render_component(&ChatComponents.queued_messages_region/1, %{
        messages: [%{"id" => "s1", "text" => "stringy"}]
      })

    rows = html |> Floki.parse_fragment!() |> Floki.find("[data-queued-message]")

    assert length(rows) == 1
    assert html =~ "stringy"
    assert html =~ ~s(data-queued-id="s1")
  end

  test "renders nothing for an empty queue" do
    html =
      render_component(&ChatComponents.queued_messages_region/1, %{messages: []})

    rows = html |> Floki.parse_fragment!() |> Floki.find("[data-queued-message]")

    assert rows == []
  end
end
