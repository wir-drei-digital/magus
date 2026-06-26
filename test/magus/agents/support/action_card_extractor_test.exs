defmodule Magus.Agents.Support.ActionCardExtractorTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Support.ActionCardExtractor

  describe "extract/1" do
    test "returns text unchanged when no action cards block" do
      text = "Here is a normal response with no action cards."
      assert {^text, nil} = ActionCardExtractor.extract(text)
    end

    test "extracts action cards from fenced block" do
      text = """
      Here are some options for you:

      ```action_cards
      {"layout":"list","cards":[{"title":"Option A","description":"First choice","action":{"type":"send_message","payload":"A"}}]}
      ```
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      assert String.trim(clean_text) == "Here are some options for you:"
      assert action_cards["layout"] == "list"
      assert length(action_cards["cards"]) == 1
      assert hd(action_cards["cards"])["title"] == "Option A"
    end

    test "extracts grid layout action cards" do
      text = """
      Check these out:

      ```action_cards
      {"layout":"grid","cards":[{"icon":"lucide-globe","title":"Search","description":"Find info","action":{"type":"navigate","payload":"/search"}},{"icon":"lucide-pen","title":"Write","description":"Draft text","action":{"type":"send_message","payload":"help me write"}}]}
      ```
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      assert String.trim(clean_text) == "Check these out:"
      assert action_cards["layout"] == "grid"
      assert length(action_cards["cards"]) == 2
    end

    test "preserves text before and after action cards block" do
      text = """
      Before the cards.

      ```action_cards
      {"layout":"list","cards":[{"title":"A","action":{"type":"send_message","payload":"a"}}]}
      ```

      After the cards.\
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      # The block is removed but surrounding text preserved
      assert clean_text =~ "Before the cards."
      assert action_cards != nil
    end

    test "returns nil for invalid JSON in action cards block" do
      text = """
      Here you go:

      ```action_cards
      {invalid json}
      ```
      """

      {returned_text, action_cards} = ActionCardExtractor.extract(text)

      assert returned_text == text
      assert action_cards == nil
    end

    test "returns nil when cards key is missing" do
      text = """
      Test:

      ```action_cards
      {"layout":"list"}
      ```
      """

      {returned_text, action_cards} = ActionCardExtractor.extract(text)

      assert returned_text == text
      assert action_cards == nil
    end

    test "handles nil input" do
      assert {nil, nil} = ActionCardExtractor.extract(nil)
    end

    test "handles empty string" do
      assert {"", nil} = ActionCardExtractor.extract("")
    end

    test "handles multiline JSON in action cards block" do
      text = """
      Choose one:

      ```action_cards
      {
        "layout": "list",
        "cards": [
          {
            "title": "Option A",
            "description": "The first option",
            "action": {"type": "send_message", "payload": "I choose A"}
          },
          {
            "title": "Option B",
            "description": "The second option",
            "action": {"type": "send_message", "payload": "I choose B"}
          }
        ]
      }
      ```
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      assert String.trim(clean_text) == "Choose one:"
      assert length(action_cards["cards"]) == 2
      assert Enum.at(action_cards["cards"], 1)["title"] == "Option B"
    end

    test "strips all blocks and uses the last valid one when multiple exist" do
      text = """
      First attempt:

      ```action_cards
      {"layout":"list","cards":[{"title":"Old","action":{"type":"send_message","payload":"old"}}]}
      ```

      Actually, here are better options:

      ```action_cards
      {"layout":"list","cards":[{"title":"New A","action":{"type":"send_message","payload":"a"}},{"title":"New B","action":{"type":"send_message","payload":"b"}}]}
      ```
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      # Both blocks stripped from text
      refute clean_text =~ "action_cards"
      assert clean_text =~ "First attempt:"
      assert clean_text =~ "Actually, here are better options:"

      # Last valid block used
      assert length(action_cards["cards"]) == 2
      assert hd(action_cards["cards"])["title"] == "New A"
    end

    test "strips all blocks even if only one is valid JSON" do
      text = """
      Broken:

      ```action_cards
      {not valid json}
      ```

      Fixed:

      ```action_cards
      {"layout":"list","cards":[{"title":"Works","action":{"type":"send_message","payload":"ok"}}]}
      ```
      """

      {clean_text, action_cards} = ActionCardExtractor.extract(text)

      refute clean_text =~ "action_cards"
      assert action_cards["cards"] |> hd() |> Map.get("title") == "Works"
    end
  end
end
