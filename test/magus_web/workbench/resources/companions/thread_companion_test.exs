defmodule MagusWeb.Workbench.Resources.Companions.ThreadCompanionTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.Companions.ThreadCompanion

  test "mounts with thread data" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, parent} =
      Magus.Chat.create_conversation(%{title: "Parent", workspace_id: ws.id}, actor: user)

    {:ok, msg} =
      Magus.Chat.create_message(
        %{conversation_id: parent.id, text: "branch here"},
        actor: user
      )

    {:ok, thread} =
      Magus.Chat.create_thread(
        %{parent_conversation_id: parent.id, branched_at_message_id: msg.id},
        actor: user
      )

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        ThreadCompanion,
        session: %{
          "thread_id" => thread.id,
          "conversation_id" => parent.id,
          "user_id" => user.id,
          "tab_id" => "tab_abc"
        }
      )

    assert html =~ thread.id or html =~ "Thread" or html =~ "branch here"
  end

  describe "state.change waiting indicator" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, parent} =
        Magus.Chat.create_conversation(%{title: "Parent", workspace_id: ws.id}, actor: user)

      {:ok, msg} =
        Magus.Chat.create_message(%{conversation_id: parent.id, text: "branch"}, actor: user)

      {:ok, thread} =
        Magus.Chat.create_thread(
          %{parent_conversation_id: parent.id, branched_at_message_id: msg.id},
          actor: user
        )

      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          ThreadCompanion,
          session: %{
            "thread_id" => thread.id,
            "conversation_id" => parent.id,
            "user_id" => user.id,
            "tab_id" => "tab_abc"
          }
        )

      %{lv: lv}
    end

    defp waiting?(lv) do
      :sys.get_state(lv.pid).socket.assigns.waiting_for_response
    end

    defp send_state(lv, state) do
      send(lv.pid, %{type: "state.change", state: state})
      # Force a render round-trip so the prior handle_info is processed.
      _ = Phoenix.LiveViewTest.render(lv)
      :ok
    end

    # Regression: these states previously fell outside the hardcoded
    # [:thinking, :planning, :running_tools] list, so the indicator vanished.
    for state <- [
          :thinking,
          :reasoning,
          :running_tools,
          :running,
          :generating_image,
          :generating_video
        ] do
      test "#{state} keeps the waiting indicator on", %{lv: lv} do
        send_state(lv, unquote(state))
        assert waiting?(lv), "expected waiting_for_response to be true for #{unquote(state)}"
      end
    end

    test "idle clears the waiting indicator", %{lv: lv} do
      send_state(lv, :reasoning)
      assert waiting?(lv)

      send_state(lv, :idle)
      refute waiting?(lv)
    end
  end
end
