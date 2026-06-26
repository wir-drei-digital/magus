defmodule Magus.Knowledge.KnowledgeCollection.Changes.SyncLogger do
  @moduledoc """
  Persists sync log entries directly to the DB and broadcasts update events.

  Each call appends an entry to the collection's `sync_log` column and
  broadcasts a `sync.log_updated` event on the source's PubSub topic so
  the UI can refresh.

  Log entries are compact maps: `%{t: iso8601, l: "info", m: "message"}`.
  Capped at 1000 entries — oldest are dropped.
  """

  require Ash.Query

  @max_entries 1000

  @doc "Appends a log entry, persists to DB, and broadcasts an update event."
  def log(collection_id, level, message) when is_atom(level) do
    entry = %{
      t: DateTime.utc_now() |> DateTime.to_iso8601(),
      l: Atom.to_string(level),
      m: message
    }

    collection = Ash.get!(Magus.Knowledge.KnowledgeCollection, collection_id, authorize?: false)
    existing = collection.sync_log || []
    updated = Enum.take(existing ++ [entry], -@max_entries)

    Magus.Knowledge.update_sync_status(
      collection,
      %{sync_log: updated},
      authorize?: false
    )

    broadcast_update(collection)
  end

  @doc "Convenience for info-level log."
  def info(collection_id, message), do: log(collection_id, :info, message)

  @doc "Convenience for warning-level log."
  def warn(collection_id, message), do: log(collection_id, :warn, message)

  @doc "Convenience for error-level log."
  def error(collection_id, message), do: log(collection_id, :error, message)

  defp broadcast_update(collection) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "knowledge:source:#{collection.knowledge_source_id}",
      %{type: "sync.log_updated"}
    )
  end
end
