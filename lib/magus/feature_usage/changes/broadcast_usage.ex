defmodule Magus.FeatureUsage.Changes.BroadcastUsage do
  @moduledoc """
  Broadcasts a PubSub event after a feature usage event is tracked.

  Broadcasts to the topic `feature_usage:{user_id}` with a map containing
  the feature, action, user_id, metadata, and timestamp.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, event ->
      Phoenix.PubSub.broadcast(
        Magus.PubSub,
        "feature_usage:#{event.user_id}",
        %{
          type: "feature.used",
          feature: event.feature,
          action: event.action,
          user_id: event.user_id,
          metadata: event.metadata,
          timestamp: event.inserted_at
        }
      )

      {:ok, event}
    end)
  end
end
