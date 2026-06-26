defmodule Magus.Plan.Task.Changes.BroadcastTaskEvent do
  @moduledoc """
  Broadcasts task changes via PubSub so the task pane updates in real-time.

  Publishes to topic `tasks:conversation:{conversation_id}` using
  `Magus.Endpoint.broadcast` for consistency with other PubSub topics.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, task ->
      event_type =
        case changeset.action.type do
          :create -> "task.created"
          :update -> "task.updated"
          _ -> "task.changed"
        end

      case Magus.Endpoint.broadcast(
             "tasks:conversation:#{task.conversation_id}",
             event_type,
             %{task: task}
           ) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Task broadcast failed: #{inspect(reason)}")
      end

      {:ok, task}
    end)
  end
end
