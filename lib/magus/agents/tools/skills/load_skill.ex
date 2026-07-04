defmodule Magus.Agents.Tools.Skills.LoadSkill do
  @moduledoc """
  Tool for loading skill instructions into the conversation context.

  When skills are loaded, their content is returned as the tool result,
  allowing the AI to use the specialized instructions for the current task.
  Multiple skills can be loaded by calling this tool multiple times.

  ## Usage with Jido AI

      # As a tool in ChatResponder
      tools = [Magus.Agents.Tools.Skills.LoadSkill]
      tool_contexts = %{
        Magus.Agents.Tools.Skills.LoadSkill => %{}
      }

  ## Example

      Input: %{skill_name: "poetry_writing"}
      Output: %{skill: "poetry_writing", content: "# Poetry Writing\n\nWhen helping..."}
  """

  use Jido.Action,
    name: "load_skill",
    description: """
    Load specialized instructions and tools for a specific task type.
    Loading a skill unlocks its specialized tools and provides detailed guidance.
    You can load multiple skills — each adds to the available toolset.

    Available skills are listed in your system prompt under "Available Skills".
    """,
    schema: [
      skill_name: [
        type: :string,
        required: true,
        doc: "Name of the skill to load (from the available skills list)"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Loading skill..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{skill: name}), do: "Loaded: #{name}"
  def summarize_output(%{error: _}), do: "Skill not found"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    ref = get_param(params, :skill_name)

    Magus.Skills.Loader.load(
      ref,
      %{
        conversation_id: get_context_value(context, :conversation_id),
        user_id: get_context_value(context, :user_id),
        user: get_context_value(context, :user)
      },
      source: :approval_card
    )
  end
end
