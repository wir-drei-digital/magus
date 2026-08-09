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

  describe "shared fixtures with the SPA stripper" do
    # These exact strings are asserted in
    # frontend/src/lib/chat/action-cards.test.ts. The SPA mirrors this regex to
    # hide the block mid-stream, so the two must agree. If you change the fence
    # format here, change it there in the same commit.
    test "complete block is stripped, surrounding prose kept" do
      text =
        "Here are options.\n```action_cards\n{\"cards\":[{\"title\":\"A\",\"action\":{\"type\":\"send_message\",\"payload\":\"a\"}}]}\n```\nTrailing."

      {clean, cards} = Magus.Agents.Support.ActionCardExtractor.extract(text)
      assert clean == "Here are options.\nTrailing."
      assert cards != nil
    end

    test "an unrelated fenced block is left alone" do
      text = "See:\n```json\n{\"a\":1}\n```"
      {clean, cards} = Magus.Agents.Support.ActionCardExtractor.extract(text)
      assert clean == text
      assert cards == nil
    end

    test "a prefix-superset tag is left alone" do
      # This is the case the SPA's (?![A-Za-z0-9_]) tag boundary exists for.
      # Without a mirrored assertion here, loosening THIS regex (\s* -> [^\n]*)
      # to match "```action_cards_backup" would leave both suites green.
      text = "See:\n```action_cards_backup\n{\"x\":1}\n```"
      {clean, cards} = Magus.Agents.Support.ActionCardExtractor.extract(text)
      assert clean == text
      assert cards == nil

      # ...but that payload alone does NOT pin the regex: `{"x":1}` has no
      # "cards" key, so `extract/1` returns the original text via the
      # `action_cards == nil` branch whether or not the fence matched. Only a
      # block carrying a VALID card distinguishes "the tag didn't match" from
      # "the tag matched but the JSON was unusable" — verified by temporarily
      # loosening the regex, which turns exactly this assertion red.
      valid_json =
        "{\"cards\":[{\"title\":\"A\",\"action\":{\"type\":\"send_message\",\"payload\":\"a\"}}]}"

      superset = "See:\n```action_cards_backup\n" <> valid_json <> "\n```"
      assert {^superset, nil} = Magus.Agents.Support.ActionCardExtractor.extract(superset)

      # The SPA twin asserts the same fence with trailing prose after it, since
      # its OPEN_FENCE pass would otherwise swallow everything to end-of-string.
      with_trailer = superset <> "\nDone."
      assert {^with_trailer, nil} = Magus.Agents.Support.ActionCardExtractor.extract(with_trailer)
    end
  end
end
