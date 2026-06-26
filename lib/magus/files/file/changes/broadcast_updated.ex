defmodule Magus.Files.File.Changes.BroadcastUpdated do
  @moduledoc """
  After :replace_content completes, publishes
  {:file_updated, file_id, source, request_id} to the file's PubSub topic
  so any open SpreadsheetCompanion (or other subscriber) can refresh.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    request_id = Ash.Changeset.get_argument(changeset, :request_id)
    source = Ash.Changeset.get_argument(changeset, :source) || :user

    Ash.Changeset.after_action(changeset, fn _cs, file ->
      Phoenix.PubSub.broadcast(
        Magus.PubSub,
        "files:#{file.id}",
        {:file_updated, file.id, source, request_id}
      )

      {:ok, file}
    end)
  end
end
