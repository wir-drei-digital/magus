defmodule Magus.Chat.Conversation.Changes.DeleteFullConversation do
  @moduledoc """
  Handles full conversation deletion with proper cleanup of external resources.

  Most related DB records are cleaned up automatically via ON DELETE CASCADE/SET NULL
  foreign keys (see migration 20260321100000). This change only handles resources
  that require application-level cleanup before deletion:

  - **Files**: Deletes from storage backend (S3/local) and decrements storage usage
  - **Sandboxes**: Enqueues out-of-band destruction of remote sandbox sprites
    (`Magus.Sandbox.Workers.DestroyRemoteSandbox`). The sprite ids are captured
    here, before the DB cascade removes the rows, and the Oban jobs are inserted
    in the deletion transaction so they persist only if the delete commits. This
    keeps remote HTTP calls and retries out of the transaction (magus-2621).
  """
  use Ash.Resource.Change
  require Ash.Query

  alias Magus.Sandbox.Workers.DestroyRemoteSandbox

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      conversation_id = changeset.data.id

      # Recursively clean up child (task) conversations first, so their
      # files/sandboxes get proper application-level cleanup before the
      # DB CASCADE deletes the child conversation records.
      Magus.Chat.Conversation
      |> Ash.Query.filter(parent_conversation_id == ^conversation_id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(fn child ->
        cleanup_external_resources(child.id)
      end)

      cleanup_external_resources(conversation_id)

      changeset
    end)
  end

  defp cleanup_external_resources(conversation_id) do
    # Delete files via Ash to trigger storage cleanup + usage decrement
    Magus.Files.File
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: :stream)

    enqueue_remote_sandbox_cleanup(conversation_id)
  end

  # Capture sprite ids now, before the DB cascade removes the sandbox rows, and
  # enqueue their remote destruction. Oban.insert! participates in the deletion
  # transaction, so the jobs persist only if the delete commits; Oban then runs
  # them out of band with durable retries.
  defp enqueue_remote_sandbox_cleanup(conversation_id) do
    Magus.Sandbox.Sandbox
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn sandbox ->
      if sandbox.sprite_id do
        %{
          "sandbox_id" => sandbox.id,
          "provider" => to_string(sandbox.provider),
          "sprite_id" => sandbox.sprite_id
        }
        |> DestroyRemoteSandbox.new()
        |> Oban.insert!()
      end
    end)
  end
end
