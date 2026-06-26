defmodule Magus.Agents.Support.HomeConversation do
  @moduledoc """
  Find or create an agent's dedicated home conversation.

  Each custom agent may have a single "home" conversation — a task conversation
  with no parent — used for heartbeat jobs and autonomous work.  An advisory lock
  prevents duplicate creation under concurrent requests.
  """

  require Ash.Query

  @doc """
  Returns the existing home conversation or creates one inside an advisory-locked
  transaction.
  """
  def ensure(user_id, custom_agent_id) do
    lock_key = "agent-home:#{user_id}:#{custom_agent_id}"

    case Magus.Repo.transaction(fn ->
           with :ok <- advisory_lock(lock_key),
                {:ok, conversation} <- find_or_create(user_id, custom_agent_id) do
             conversation
           else
             {:error, reason} -> Magus.Repo.rollback(reason)
           end
         end) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the home conversation if it exists, or `{:ok, nil}` when none has been
  created yet.
  """
  def find(user_id, custom_agent_id) do
    Magus.Chat.Conversation
    |> Ash.Query.filter(
      user_id == ^user_id and custom_agent_id == ^custom_agent_id and
        is_task_conversation == true and is_nil(parent_conversation_id)
    )
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp advisory_lock(lock_key) do
    case Magus.Repo.query("SELECT pg_advisory_xact_lock(hashtext($1), 1)", [lock_key]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_or_create(user_id, custom_agent_id) do
    case find(user_id, custom_agent_id) do
      {:ok, nil} ->
        with {:ok, actor} <- Magus.Accounts.get_user(user_id, authorize?: false) do
          Magus.Chat.create_conversation(
            %{
              title: "Agent Home",
              custom_agent_id: custom_agent_id,
              chat_mode: :chat,
              is_task_conversation: true
            },
            actor: actor
          )
        end

      {:ok, conversation} ->
        {:ok, conversation}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
