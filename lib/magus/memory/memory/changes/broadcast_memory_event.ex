defmodule Magus.Memory.Memory.Changes.BroadcastMemoryEvent do
  @moduledoc """
  Ash change that broadcasts PubSub events after memory operations.

  Determines the event type from the changeset action type and broadcasts
  via `Magus.Memory.Signals`.
  """

  use Ash.Resource.Change

  alias Magus.Memory.Signals

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      event_type = determine_event_type(changeset)
      user_id = record.user_id

      case event_type do
        :created -> Signals.memory_created(user_id, record)
        :updated -> Signals.memory_updated(user_id, record)
        :deleted -> Signals.memory_deleted(user_id, record)
        _ -> :ok
      end

      {:ok, record}
    end)
  end

  # For a destroy action, `after_action` receives the destroyed record
  # struct (not persisted anymore) as `record`, which is exactly what
  # Signals.memory_deleted/2 needs to broadcast.

  defp determine_event_type(changeset) do
    case changeset.action.type do
      :create -> :created
      :update -> :updated
      :destroy -> :deleted
      _ -> nil
    end
  end
end
