defmodule Magus.Agents.Workers.ResumeGenerationWorker do
  @moduledoc """
  Oban worker that re-triggers generation for a conversation interrupted
  during deployment.

  When a deployment interrupts an in-flight generation, one of these jobs
  is inserted per conversation. After the new instance boots, the worker:

  1. Checks whether a complete agent response already exists (drain finished ok)
  2. Finds the most recent `:user` message in the conversation
  3. Runs the signal-native `Magus.Agents.Dispatcher` — same path as a normal user message
  4. The LLM rebuilds context from DB (including intermediate tool results
     persisted by `persist_intermediate`) and naturally continues

  ## Edge cases

  - **Generation already completed**: Detected by checking for a complete agent
    message after the last user message. Job is cancelled, no duplicate response.
  - **User sent a new message**: The `ensure_idle` guard in the LLM strategy
    prevents duplicate generations — the new message takes priority.
  - **Conversation deleted**: The reactor fails gracefully, Oban cancels the job.
  """

  use Oban.Worker,
    queue: :chat_responses,
    max_attempts: 3,
    unique: [period: 300, keys: [:conversation_id]]

  require Logger

  alias Magus.Agents.Dispatcher

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conversation_id}}) do
    Logger.info("ResumeGenerationWorker: resuming generation for conversation #{conversation_id}")

    with {:ok, conversation} <- load_conversation(conversation_id),
         {:ok, message} <- find_last_user_message(conversation_id),
         :needs_resume <- check_completion_status(conversation_id, message) do
      case Dispatcher.dispatch_message(message, conversation.id, conversation.user_id) do
        {:ok, _result} ->
          Logger.info("ResumeGenerationWorker: dispatched for #{conversation_id}")
          :ok

        {:error, reason} ->
          Logger.error(
            "ResumeGenerationWorker: dispatch failed for #{conversation_id}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      {:cancel, reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_conversation(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, conversation} ->
        {:ok, conversation}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        Logger.warning(
          "ResumeGenerationWorker: conversation #{conversation_id} not found, cancelling"
        )

        {:cancel, :conversation_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_last_user_message(conversation_id) do
    require Ash.Query

    query =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id and role == :user)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, [message]} ->
        {:ok, message}

      {:ok, []} ->
        Logger.warning(
          "ResumeGenerationWorker: no user messages in #{conversation_id}, cancelling"
        )

        {:cancel, :no_user_messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_completion_status(conversation_id, last_user_message) do
    require Ash.Query

    query =
      Magus.Chat.Message
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and
          role == :agent and
          status == :complete and
          inserted_at > ^last_user_message.inserted_at
      )
      |> Ash.Query.limit(1)

    case Ash.read(query, authorize?: false) do
      {:ok, [_msg]} ->
        Logger.info(
          "ResumeGenerationWorker: generation already complete for #{conversation_id}, skipping"
        )

        {:cancel, :already_complete}

      {:ok, []} ->
        :needs_resume

      {:error, reason} ->
        Logger.error(
          "ResumeGenerationWorker: failed to check completion for #{conversation_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
