defmodule MagusWeb.Workbench.Resources.Companions.DraftCompanionTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Resources.Companions.DraftCompanion

  test "mounts with draft loaded" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "Draft test", workspace_id: ws.id}, actor: user)

    {:ok, draft} =
      Magus.Drafts.create_draft(conv.id, "Sample draft", "Hello world", user.id, actor: user)

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        DraftCompanion,
        session: %{
          "draft_id" => draft.id,
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab_abc"
        }
      )

    assert html =~ draft.id or html =~ "Sample draft"
  end

  test "reloads draft on draft.updated broadcast" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "Reload test", workspace_id: ws.id}, actor: user)

    {:ok, draft} =
      Magus.Drafts.create_draft(conv.id, "Original title", "Original content", user.id,
        actor: user
      )

    {:ok, lv, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        DraftCompanion,
        session: %{
          "draft_id" => draft.id,
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab_abc"
        }
      )

    {:ok, updated} =
      Magus.Drafts.update_draft_title(draft, "Updated title", actor: user)

    # Simulate the PubSub broadcast that BroadcastDraftEvent would emit
    MagusWeb.Endpoint.broadcast(
      "drafts:conversation:#{conv.id}",
      "draft.updated",
      %{draft: updated}
    )

    :ok = poll_until(fn -> Phoenix.LiveViewTest.render(lv) =~ "Updated title" end)
  end
end
