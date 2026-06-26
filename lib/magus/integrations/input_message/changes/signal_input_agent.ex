defmodule Magus.Integrations.InputMessage.Changes.SignalInputAgent do
  @moduledoc """
  Dispatches InputMessages to conversations after creation.

  This change runs after the transaction commits to ensure the message
  is persisted before processing. The DispatchInput reactor handles
  routing the message to the appropriate conversation.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        if not record.dispatched do
          # Dispatch asynchronously to not block the webhook response
          Task.Supervisor.start_child(Magus.Integrations.WebhookTaskSupervisor, fn ->
            run_dispatch(record)
          end)
        end

        {:ok, record}

      _changeset, {:error, error} ->
        {:error, error}
    end)
  end

  defp run_dispatch(input_message) do
    inputs = %{
      input_message_id: input_message.id,
      user_id: input_message.user_id
    }

    case Reactor.run(Magus.Agents.Reactors.DispatchInput, inputs, async?: false) do
      {:ok, _result} ->
        Logger.debug("Successfully dispatched input message #{input_message.id}")

      {:error, reason} ->
        Logger.error("Failed to dispatch input message #{input_message.id}: #{inspect(reason)}")
        mark_failed(input_message, reason)
    end
  end

  defp mark_failed(input_message, reason) do
    error_message =
      case reason do
        %{message: msg} -> msg
        msg when is_binary(msg) -> msg
        other -> inspect(other)
      end

    Magus.Integrations.mark_input_failed(
      input_message,
      %{error_message: error_message},
      authorize?: false
    )
  rescue
    _ -> :ok
  end
end
