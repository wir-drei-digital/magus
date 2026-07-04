defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemories do
  @moduledoc """
  Ash change module that triggers turn-level memory extraction.

  Triggered by AshOban when `extraction_due_at` has passed. Clears the
  `extraction_due_at` field, then runs extraction inline in an
  `after_transaction` hook: outside the DB transaction (LLM calls must not
  hold a connection) but inside the Oban job, so an LLM failure fails the
  job and Oban retries it. The previous version spawned a fire-and-forget
  Task here, which permanently lost the turn on any LLM error.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Agents.Actions.ExtractTurnMemories, as: ExtractAction

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.force_change_attribute(:extraction_due_at, nil)
    |> Ash.Changeset.after_transaction(fn
      _changeset, {:ok, conversation} ->
        case run_extraction(conversation) do
          :ok -> {:ok, conversation}
          {:error, reason} -> {:error, reason}
        end

      _changeset, error ->
        error
    end)
  end

  defp run_extraction(conversation) do
    case load_last_turn(conversation.id) do
      {:ok, user_message, agent_response} ->
        if String.length(user_message) > 50 and String.length(agent_response) > 100 do
          allow_global = agent_allows_global_writes?(conversation)

          case ExtractAction.run(
                 %{
                   user_id: to_string(conversation.user_id),
                   conversation_id: to_string(conversation.id),
                   user_message: user_message,
                   agent_response: agent_response,
                   allow_global_memories: allow_global
                 },
                 %{}
               ) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          :ok
        end

      :skip ->
        :ok
    end
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
        agent_msg = Enum.find(messages, fn m -> m.role == :agent and (m.text || "") != "" end)
        user_msg = Enum.find(messages, fn m -> m.role == :user and (m.text || "") != "" end)

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
