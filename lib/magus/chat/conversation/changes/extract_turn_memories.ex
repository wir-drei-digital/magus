defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemories do
  @moduledoc """
  Ash change module that triggers turn-level memory extraction.

  Triggered by AshOban when `extraction_due_at` has passed. Clears the
  `extraction_due_at` field so the trigger doesn't re-fire, then loads
  the last user message and agent response and runs extraction async.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Agents.Actions.ExtractTurnMemories, as: ExtractAction

  @impl true
  def change(changeset, _opts, _context) do
    # Clear extraction_due_at so the trigger doesn't re-fire
    changeset
    |> Ash.Changeset.force_change_attribute(:extraction_due_at, nil)
    |> Ash.Changeset.after_action(fn _changeset, conversation ->
      run_extraction(conversation)
      {:ok, conversation}
    end)
  end

  defp run_extraction(conversation) do
    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      case load_last_turn(conversation.id) do
        {:ok, user_message, agent_response} ->
          if String.length(user_message) > 50 and String.length(agent_response) > 100 do
            allow_global = agent_allows_global_writes?(conversation)

            ExtractAction.run(
              %{
                user_id: to_string(conversation.user_id),
                conversation_id: to_string(conversation.id),
                user_message: user_message,
                agent_response: agent_response,
                allow_global_memories: allow_global
              },
              %{}
            )
          end

        :skip ->
          :ok
      end
    end)
  end

  # Oban triggers provide bare conversations without preloads, so we
  # explicitly load the custom_agent association here.
  defp agent_allows_global_writes?(conversation) do
    case Ash.load(conversation, [:custom_agent], authorize?: false) do
      {:ok, %{custom_agent: %{can_write_global_memories: false}}} -> false
      _ -> true
    end
  end

  defp load_last_turn(conversation_id) do
    require Ash.Query

    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and role in [:user, :agent])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(10)
         |> Ash.read(authorize?: false) do
      {:ok, messages} ->
        agent_msg =
          Enum.find(messages, fn m -> m.role == :agent and (m.text || "") != "" end)

        user_msg =
          Enum.find(messages, fn m -> m.role == :user and (m.text || "") != "" end)

        if agent_msg && user_msg do
          {:ok, user_msg.text, agent_msg.text}
        else
          :skip
        end

      {:error, _} ->
        :skip
    end
  end
end
