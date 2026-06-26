defmodule Magus.Knowledge.KnowledgeCollection.Changes.CleanupFiles do
  @moduledoc """
  Enqueues an async Oban job to delete all files belonging to a collection
  when the collection is destroyed.

  Captures file IDs before the destroy (since the FK is nilified on cascade),
  then passes them to the worker for async deletion.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      collection_id = changeset.data.id

      file_ids =
        Magus.Files.File
        |> Ash.Query.filter(knowledge_collection_id == ^collection_id)
        |> Ash.Query.select([:id])
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      Ash.Changeset.set_context(changeset, %{cleanup_file_ids: file_ids})
    end)
    |> Ash.Changeset.after_action(fn changeset, result ->
      file_ids = changeset.context[:cleanup_file_ids] || []

      if file_ids != [] do
        %{file_ids: file_ids}
        |> Magus.Knowledge.KnowledgeCollection.Workers.CleanupFiles.new()
        |> Oban.insert()
      end

      {:ok, result}
    end)
  end
end
