defmodule MagusWeb.Components.ActionCardsTest do
  use MagusWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias MagusWeb.Components.ActionCards

  describe "action_cards/1" do
    test "renders grid layout with cards" do
      cards_data = %{
        "layout" => "grid",
        "cards" => [
          %{
            "icon" => "pencil",
            "title" => "Create a prompt",
            "description" => "Save reusable instructions",
            "action" => %{"type" => "send_message", "payload" => "Help me create a prompt"}
          },
          %{
            "icon" => "clock",
            "title" => "Set a reminder",
            "description" => "I'll follow up",
            "action" => %{"type" => "prefill", "payload" => "Remind me to"}
          }
        ]
      }

      html = render_component(&ActionCards.action_cards/1, action_cards: cards_data)

      assert html =~ "Create a prompt"
      assert html =~ "Save reusable instructions"
      assert html =~ "Set a reminder"
      assert html =~ "grid-cols-2"
    end

    test "renders list layout with letter labels" do
      cards_data = %{
        "layout" => "list",
        "cards" => [
          %{
            "title" => "Option A",
            "description" => "First",
            "action" => %{"type" => "send_message", "payload" => "A"}
          },
          %{
            "title" => "Option B",
            "description" => "Second",
            "action" => %{"type" => "send_message", "payload" => "B"}
          }
        ]
      }

      html = render_component(&ActionCards.action_cards/1, action_cards: cards_data)

      assert html =~ "Option A"
      assert html =~ "Option B"
      assert html =~ ">A</span>"
      assert html =~ ">B</span>"
    end

    test "renders navigate action as link" do
      cards_data = %{
        "layout" => "grid",
        "cards" => [
          %{
            "icon" => "arrow",
            "title" => "Go",
            "description" => "Browse",
            "action" => %{"type" => "navigate", "payload" => "/prompts"}
          }
        ]
      }

      html = render_component(&ActionCards.action_cards/1, action_cards: cards_data)
      assert html =~ "/prompts"
      assert html =~ "data-phx-link"
    end

    test "renders send_message action with phx-click" do
      cards_data = %{
        "layout" => "grid",
        "cards" => [
          %{
            "icon" => "chat",
            "title" => "Say hello",
            "description" => "Greet the AI",
            "action" => %{"type" => "send_message", "payload" => "Hello!"}
          }
        ]
      }

      html = render_component(&ActionCards.action_cards/1, action_cards: cards_data)
      assert html =~ "phx-click=\"action_card_click\""
      assert html =~ "phx-value-type=\"send_message\""
      assert html =~ "phx-value-payload=\"Hello!\""
    end

    test "renders nothing when action_cards is nil" do
      html = render_component(&ActionCards.action_cards/1, action_cards: nil)
      assert html == "" || String.trim(html) == ""
    end

    test "renders nothing when cards list is empty" do
      cards_data = %{"layout" => "grid", "cards" => []}
      html = render_component(&ActionCards.action_cards/1, action_cards: cards_data)
      assert String.trim(html) == ""
    end
  end
end
