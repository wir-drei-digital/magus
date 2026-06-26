defmodule Magus.Agents.Tools.Library.CreatePrompt do
  @moduledoc """
  Tool for creating a new prompt in the user's library.

  Supports creating both system prompts (personas/instructions that set AI behavior)
  and user prompts (reusable message templates).

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Library.CreatePrompt]
      tool_contexts = %{
        Magus.Agents.Tools.Library.CreatePrompt => %{user_id: user.id}
      }
  """

  use Jido.Action,
    name: "create_prompt",
    description: """
    Create a new prompt in the user's prompt library.
    There are two types of prompts:
    - "system": A persona or instruction set that defines how the AI should behave. These are prepended to every message in a conversation when activated. Examples: "Act as a senior Elixir developer", "You are a creative writing coach".
    - "user": A reusable message template that the user can quickly insert. Examples: "Summarize this article", "Review this code for bugs".
    Always ask the user what type they want if unclear. System prompts are more common for onboarding.
    """,
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The name/title of the prompt (e.g., 'Coding Mentor', 'Article Summarizer')"
      ],
      content: [
        type: :string,
        required: true,
        doc: "The full prompt text/instructions"
      ],
      type: [
        type: {:in, [:system, :user]},
        required: true,
        doc:
          "The prompt type: 'system' for personas/behavior instructions, 'user' for reusable templates"
      ],
      description: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Optional short description of what this prompt does"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3, validate_context: 2]

  def display_name, do: "Creating prompt..."

  def summarize_output(%{success: true, name: name}), do: "Created: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        create_prompt(params, ctx.user_id)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp create_prompt(params, user_id) do
    name = get_param(params, :name)
    content = get_param(params, :content)
    type = get_param(params, :type) |> normalize_type()
    description = get_param(params, :description, nil)

    attrs =
      %{name: name, content: content, type: type}
      |> maybe_put(:description, description)

    # create action uses relate_actor(:user), so we need a User struct
    actor = %Magus.Accounts.User{id: user_id}

    case Magus.Library.create_prompt(attrs, actor: actor) do
      {:ok, prompt} ->
        {:ok,
         %{
           success: true,
           id: prompt.id,
           name: prompt.name,
           type: to_string(prompt.type),
           message:
             "Prompt '#{prompt.name}' has been created as a #{prompt.type} prompt. " <>
               type_hint(prompt.type)
         }}

      {:error, error} ->
        Logger.error("CreatePrompt: failed to create prompt", error: inspect(error))
        {:ok, %{error: Magus.Agents.Tools.Helpers.extract_error_message(error)}}
    end
  end

  defp normalize_type("system"), do: :system
  defp normalize_type("user"), do: :user
  defp normalize_type(atom) when is_atom(atom), do: atom

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp type_hint(:system) do
    "You can activate it on any conversation from the prompt selector."
  end

  defp type_hint(:user) do
    "You can use it as a quick-insert template in any conversation."
  end
end
