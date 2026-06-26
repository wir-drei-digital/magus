defmodule Magus.Chat.Message.Changes.SignalAgent do
  @moduledoc """
  Ash change that signals the conversation agent when a user message is created.

  This change delegates to the signal-native `Magus.Agents.Dispatcher` which orchestrates:

  1. Loading the conversation with all required relationships
  2. Resolving model keys (conversation > user > system default)
  3. Starting/getting the ConversationAgent
  4. Sending the message.user signal

  ## Error Handling

  If dispatch fails, an error event is broadcast to the conversation's
  PubSub channel so the UI can display the error to the user. The message
  creation itself still succeeds so the user's message is preserved.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Agents.{Dispatcher, Signals}

  def change(changeset, _opts, _context) do
    # Use after_transaction to ensure the message exists in the database
    # before dispatch tries to load related data.
    Ash.Changeset.after_transaction(changeset, fn
      _cs, {:ok, message} ->
        if dispatchable?(message) do
          Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
            dispatch_to_agent(message)
          end)
        end

        {:ok, message}

      _cs, {:error, _} = error ->
        error
    end)
  end

  @doc "Only complete user messages dispatch to the agent. Queued messages do not."
  def dispatchable?(%{role: :user, status: status}), do: status != :queued
  def dispatchable?(_), do: false

  defp dispatch_to_agent(message) do
    dispatch_normal(message)
    schedule_extraction(message.conversation_id)
  end

  defp dispatch_normal(message) do
    case Dispatcher.dispatch_user_message(message) do
      {:ok, result} ->
        Logger.debug(
          "SignalAgent: Dispatched message #{message.id} to agent, result: #{inspect(result)}"
        )

        :ok

      {:error, reason} ->
        error_message = format_dispatch_errors(reason)
        Logger.error("SignalAgent: dispatch failed for message #{message.id}: #{error_message}")

        # Broadcast error to conversation so UI can display it
        Signals.error(
          to_string(message.conversation_id),
          to_string(message.id),
          "agent_error",
          error_message
        )

        :ok
    end
  end

  defp schedule_extraction(conversation_id) do
    due_at = DateTime.add(DateTime.utc_now(), 60, :second)

    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, conversation} ->
        Magus.Chat.schedule_extraction(conversation, %{extraction_due_at: due_at},
          authorize?: false
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp format_dispatch_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(&format_single_error/1)
    |> Enum.join("; ")
  end

  defp format_dispatch_errors(error), do: format_single_error(error)

  defp format_single_error(%{message: message}) when is_binary(message), do: message
  defp format_single_error(error) when is_exception(error), do: Exception.message(error)
  defp format_single_error(error) when is_binary(error), do: error
  defp format_single_error(error), do: inspect(error)
end
