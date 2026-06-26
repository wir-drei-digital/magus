defmodule Magus.Agents.Tools.Library.ListPrompts do
  @moduledoc """
  Tool for listing the user's saved prompts from their library.

  Returns both system prompts (personas/instructions) and user prompts (reusable templates).
  Supports filtering by type.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Library.ListPrompts]
      tool_contexts = %{
        Magus.Agents.Tools.Library.ListPrompts => %{user_id: user.id}
      }
  """

  use Jido.Action,
    name: "list_prompts",
    description: """
    List the user's saved prompts from their prompt library.
    Use this to show the user what prompts they have, or to check if they already have prompts before creating new ones.
    Prompts come in two types:
    - "system" prompts are personas/instructions that set the AI's behavior (e.g., "Act as a coding mentor")
    - "user" prompts are reusable message templates (e.g., "Summarize this article")
    You can filter by type or list all prompts.
    """,
    schema: [
      type: [
        type: {:or, [{:in, [:system, :user]}, nil]},
        default: nil,
        doc:
          "Filter by prompt type: 'system' for personas/instructions, 'user' for templates. Omit to list all."
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers,
    only: [get_param: 2, get_context_value: 2, validate_context: 2]

  def display_name, do: "Listing prompts..."

  def summarize_output(%{prompts: prompts}) when is_list(prompts),
    do: "Found #{length(prompts)} prompt(s)"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        workspace_id = get_context_value(context, :workspace_id)
        type = get_param(params, :type)
        list_prompts(ctx.user_id, workspace_id, type)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp list_prompts(user_id, workspace_id, type) do
    # my_prompts and my_prompts_by_type filter by actor(:id), so we need a User struct
    actor = %Magus.Accounts.User{id: user_id}
    atom_type = normalize_type(type)

    case fetch_prompts(actor, workspace_id, atom_type) do
      {:ok, prompts} ->
        formatted =
          Enum.map(prompts, fn p ->
            %{
              id: p.id,
              name: p.name,
              type: to_string(p.type),
              description: p.description,
              content_preview: String.slice(p.content || "", 0, 200),
              chat_mode: p.chat_mode && to_string(p.chat_mode)
            }
          end)

        {:ok, %{prompts: formatted, count: length(formatted)}}

      {:error, error} ->
        Logger.error("ListPrompts: failed to list prompts", error: inspect(error))
        {:ok, %{error: Magus.Agents.Tools.Helpers.extract_error_message(error)}}
    end
  end

  defp fetch_prompts(actor, nil, nil), do: Magus.Library.my_prompts(actor: actor)

  defp fetch_prompts(actor, nil, atom_type),
    do: Magus.Library.my_prompts_by_type(atom_type, actor: actor)

  defp fetch_prompts(actor, workspace_id, nil),
    do: Magus.Library.workspace_prompts(workspace_id, actor: actor)

  defp fetch_prompts(actor, workspace_id, atom_type),
    do: Magus.Library.workspace_prompts_by_type(workspace_id, atom_type, actor: actor)

  defp normalize_type(nil), do: nil
  defp normalize_type("system"), do: :system
  defp normalize_type("user"), do: :user
  defp normalize_type(:system), do: :system
  defp normalize_type(:user), do: :user
  defp normalize_type(_), do: nil
end
