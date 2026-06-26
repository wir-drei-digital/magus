defmodule Magus.Agents.Support.ActionCardExtractor do
  @moduledoc """
  Extracts action card JSON blocks from agent response text.

  The agent emits action cards using a fenced code block:

      ```action_cards
      {"layout":"list","cards":[{"title":"Option A","action":{"type":"send_message","payload":"A"}}]}
      ```

  This module extracts and parses those blocks, returning the cleaned text
  and the parsed action cards map. If multiple blocks are present, all are
  stripped from the text and the last valid one is used.
  """

  @action_cards_block ~r/\n?```action_cards\s*\n(.*?)\n```/s

  @doc """
  Extracts action cards from text.

  Returns `{clean_text, action_cards}` where `action_cards` is a map or nil.
  If multiple action_cards blocks exist, all are stripped and the last valid one is used.
  """
  @spec extract(String.t()) :: {String.t(), map() | nil}
  def extract(text) when is_binary(text) do
    matches = Regex.scan(@action_cards_block, text, capture: :all)

    case matches do
      [] ->
        {text, nil}

      _ ->
        clean_text =
          Enum.reduce(matches, text, fn [full_match | _], acc ->
            String.replace(acc, full_match, "", global: false)
          end)
          |> String.trim_trailing()

        action_cards =
          matches
          |> Enum.reverse()
          |> Enum.find_value(fn [_full, json_content] ->
            case Jason.decode(String.trim(json_content)) do
              {:ok, %{"cards" => cards} = parsed} when is_list(cards) ->
                valid_cards = Enum.filter(cards, &valid_card?/1)
                if valid_cards != [], do: %{parsed | "cards" => valid_cards}, else: nil

              _ ->
                nil
            end
          end)

        if action_cards do
          {clean_text, action_cards}
        else
          {text, nil}
        end
    end
  end

  def extract(text), do: {text, nil}

  @allowed_action_types ~w(send_message prefill navigate)

  defp valid_card?(%{"title" => title, "action" => %{"type" => type}})
       when is_binary(title) and type in @allowed_action_types,
       do: true

  defp valid_card?(_), do: false
end
