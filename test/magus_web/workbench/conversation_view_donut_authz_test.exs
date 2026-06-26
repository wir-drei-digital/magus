defmodule MagusWeb.Workbench.ConversationViewDonutAuthzTest do
  @moduledoc """
  LiveView tests for the context-window donut authorization (read-only donut for
  non-owner members; owner-only controls; defensive handlers).

  Mounts ConversationView directly with `live_isolated` (mirrors
  conversation_view_test.exs) so we can mount as the owner or as an accepted
  multiplayer member and assert on the rendered control row + handler behaviour.
  """
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators
  import Phoenix.LiveViewTest

  alias Magus.Agents.Support.AiAgent
  alias Magus.Chat
  alias MagusWeb.Workbench.Resources.ConversationView

  setup do
    owner = generate(user())
    ensure_workspace_plan(owner)
    {:ok, conv} = Chat.create_conversation(%{title: "shared donut"}, actor: owner)
    {:ok, _} = Chat.enable_multiplayer(conv, actor: owner)
    # Seed a concrete window so the donut renders with data for everyone.
    {:ok, _cw} = Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
    %{owner: owner, conv: conv}
  end

  defp accepted_member(conv, owner) do
    member = generate(user())

    {:ok, membership} =
      Chat.add_conversation_member(conv.id, member.id, %{invited_by_id: owner.id},
        authorize?: false
      )

    {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)
    member
  end

  defp mount_view(user, conversation_id) do
    Phoenix.LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      ConversationView,
      session: %{
        "conversation_id" => conversation_id,
        "user_id" => user.id,
        "tab_id" => "tab_donut"
      }
    )
  end

  test "owner sees the donut control row", %{owner: owner, conv: conv} do
    {:ok, lv, _html} = mount_view(owner, conv.id)

    assert has_element?(lv, "[data-role=context-donut]")
    assert has_element?(lv, "[data-role=context-clear]")
    assert has_element?(lv, "[data-role=context-compact]")
    assert has_element?(lv, "[data-role=context-strategy-rolling]")
  end

  test "non-owner accepted member sees the read-only donut but no control row", %{
    owner: owner,
    conv: conv
  } do
    member = accepted_member(conv, owner)

    {:ok, lv, _html} = mount_view(member, conv.id)

    # The donut + breakdown still render read-only for the member.
    assert has_element?(lv, "[data-role=context-donut]")
    assert has_element?(lv, "[data-role=context-breakdown]")

    # The owner-only controls are absent.
    refute has_element?(lv, "[data-role=context-clear]")
    refute has_element?(lv, "[data-role=context-compact]")
    refute has_element?(lv, "[data-role=context-strategy-rolling]")
    refute has_element?(lv, "[data-role=context-strategy-compact]")
  end

  test "non-owner member's clear_context event is a no-op and does not crash", %{
    owner: owner,
    conv: conv
  } do
    member = accepted_member(conv, owner)
    {:ok, lv, _html} = mount_view(member, conv.id)

    # Forge the bubbled control events that a non-owner should never reach. The
    # owner-only policy returns Forbidden; the handler must no-op rather than
    # raise a MatchError.
    assert render_hook(lv, "clear_context", %{})
    assert render_hook(lv, "compact_context", %{})
    assert render_hook(lv, "set_context_strategy", %{"strategy" => "compact"})

    # The LiveView is still alive after all three.
    assert Process.alive?(lv.pid)
    assert has_element?(lv, "[data-role=context-donut]")
  end

  # 3c: re-clicking the already-active strategy toggles the per-conversation
  # override OFF (back to nil = inherit the app default), mirroring the SPA.
  test "owner re-clicking the active strategy clears the override to nil", %{
    owner: owner,
    conv: conv
  } do
    # Establish an explicit per-conversation override first.
    {:ok, cw} = Chat.set_context_strategy_for_conversation(conv.id, :compact, actor: owner)
    assert cw.strategy == :compact

    {:ok, lv, _html} = mount_view(owner, conv.id)

    # Re-clicking the active strategy must clear the override (toggle off).
    render_hook(lv, "set_context_strategy", %{"strategy" => "compact"})

    {:ok, refreshed} = Chat.get_context_window(conv.id, actor: owner)
    assert refreshed.strategy == nil
  end

  test "owner clicking a different strategy sets that explicit override", %{
    owner: owner,
    conv: conv
  } do
    {:ok, cw} = Chat.set_context_strategy_for_conversation(conv.id, :compact, actor: owner)
    assert cw.strategy == :compact

    {:ok, lv, _html} = mount_view(owner, conv.id)

    # Clicking a DIFFERENT strategy switches the override (does not clear it).
    render_hook(lv, "set_context_strategy", %{"strategy" => "rolling"})

    {:ok, refreshed} = Chat.get_context_window(conv.id, actor: owner)
    assert refreshed.strategy == :rolling
  end

  test "new-chat (nil conversation) context events are a no-op and do not crash" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, lv, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        ConversationView,
        session: %{
          "conversation_id" => "new",
          "user_id" => user.id,
          "tab_id" => "tab_new"
        }
      )

    # On the new-chat composer there is no conversation; conv.id would raise a
    # BadMapError. The nil-guard must short-circuit instead.
    assert render_hook(lv, "clear_context", %{})
    assert render_hook(lv, "compact_context", %{})
    assert render_hook(lv, "set_context_strategy", %{"strategy" => "rolling"})

    assert Process.alive?(lv.pid)
  end
end
