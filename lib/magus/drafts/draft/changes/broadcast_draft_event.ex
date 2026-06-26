defmodule Magus.Drafts.Draft.Changes.BroadcastDraftEvent do
  @moduledoc """
  Broadcasts draft changes via PubSub so the draft pane updates in real-time.

  Publishes to topic `drafts:conversation:{conversation_id}` using
  `Magus.Endpoint.broadcast` for consistency with other PubSub topics.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draft ->
      event_type =
        case changeset.action.type do
          :create -> "draft.created"
          :update -> "draft.updated"
          _ -> "draft.changed"
        end

      case Magus.Endpoint.broadcast(
             "drafts:conversation:#{draft.conversation_id}",
             event_type,
             %{draft: draft}
           ) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Draft broadcast failed: #{inspect(reason)}")
      end

      {:ok, draft}
    end)
  end
end
