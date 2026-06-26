defmodule Magus.Agents.Tools.DiceRoll do
  @moduledoc """
  Dice rolling tool for tabletop RPG-style dice notation.

  Supports standard dice notation like:
  - `2d6` - Roll 2 six-sided dice
  - `1d20` - Roll 1 twenty-sided die
  - `3d8` - Roll 3 eight-sided dice

  Returns detailed results showing each individual roll and the total.

  ## Usage with Jido AI

      # As a tool in ChatResponder
      tools = [Magus.Agents.Tools.DiceRoll]

  ## Example Output

      Input: "2d6"
      Output: %{dice: "2d6", rolls: [3, 5], total: 8, formatted: "2d6 -> 3 + 5 = 8"}
  """

  use Jido.Action,
    name: "roll_dice",
    description: """
    Roll dice using standard tabletop RPG notation (e.g., 2d6, 1d20, 3d8).
    Use this when the user wants to roll dice for games, random decisions, or fun.
    The notation is NdS where N is the number of dice and S is the number of sides.
    """,
    schema: [
      dice: [
        type: :string,
        required: true,
        doc: "Dice notation in the format NdS (e.g., 2d6, 1d20, 3d8)"
      ]
    ]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Rolling dice..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{formatted: formatted}), do: "Rolled: #{formatted}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @impl true
  def run(params, _context) do
    dice_notation = get_param(params, :dice) || ""

    case parse_dice_notation(dice_notation) do
      {:ok, count, sides} ->
        rolls = for _ <- 1..count, do: :rand.uniform(sides)
        total = Enum.sum(rolls)

        formatted =
          if count == 1 do
            "#{dice_notation} -> #{total}"
          else
            rolls_str = Enum.join(rolls, " + ")
            "#{dice_notation} -> #{rolls_str} = #{total}"
          end

        {:ok,
         %{
           dice: dice_notation,
           rolls: rolls,
           total: total,
           formatted: formatted
         }}

      {:error, reason} ->
        {:ok,
         %{
           error: reason,
           hint: "Use dice notation like 2d6, 1d20, or 3d8"
         }}
    end
  end

  defp parse_dice_notation(notation) do
    notation = String.trim(notation) |> String.downcase()

    case Regex.run(~r/^(\d+)d(\d+)$/, notation) do
      [_, count_str, sides_str] ->
        count = String.to_integer(count_str)
        sides = String.to_integer(sides_str)

        cond do
          count < 1 -> {:error, "Must roll at least 1 die"}
          count > 100 -> {:error, "Cannot roll more than 100 dice"}
          sides < 2 -> {:error, "Dice must have at least 2 sides"}
          sides > 1000 -> {:error, "Dice cannot have more than 1000 sides"}
          true -> {:ok, count, sides}
        end

      nil ->
        {:error, "Invalid dice notation. Expected format: NdS (e.g., 2d6)"}
    end
  end
end
