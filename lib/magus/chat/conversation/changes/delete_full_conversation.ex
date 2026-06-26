defmodule Magus.Chat.Conversation.Changes.DeleteFullConversation do
  @moduledoc """
  Handles full conversation deletion with proper cleanup of external resources.

  Most related DB records are cleaned up automatically via ON DELETE CASCADE/SET NULL
  foreign keys (see migration 20260321100000). This change only handles resources
  that require application-level cleanup before deletion:

  - **Files**: Deletes from storage backend (S3/local) and decrements storage usage
  - **Sandboxes**: Destroys remote sandbox sprites via provider API
  """
  use Ash.Resource.Change
  require Ash.Query
  require Logger

  alias Magus.Sandbox.Provider

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

    # Destroy remote sandbox sprites before DB cascade removes the records
    destroy_remote_sandboxes(conversation_id)
  end

  defp destroy_remote_sandboxes(conversation_id) do
    Magus.Sandbox.Sandbox
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn sandbox ->
      if sandbox.sprite_id do
        client = Provider.client_for(sandbox)
        destroy_with_retry(client, sandbox)
      end
    end)
  end

  defp destroy_with_retry(client, sandbox, attempt \\ 1) do
    case apply(client, :destroy, [sandbox.sprite_id]) do
      :ok ->
        Logger.debug(
          "Destroyed #{sandbox.provider} resource #{sandbox.sprite_id} for sandbox #{sandbox.id}"
        )

      {:error, :not_found} ->
        Logger.debug(
          "#{sandbox.provider} resource #{sandbox.sprite_id} already gone for sandbox #{sandbox.id}"
        )

      {:error, :not_configured} ->
        Logger.debug(
          "#{sandbox.provider} not configured, skipping destroy for sandbox #{sandbox.id}"
        )

      {:error, _reason} when attempt < 2 ->
        Logger.warning(
          "Retrying destroy for #{sandbox.provider} resource #{sandbox.sprite_id} (attempt #{attempt})"
        )

        Process.sleep(1_000)
        destroy_with_retry(client, sandbox, attempt + 1)

      {:error, reason} ->
        Logger.error(
          "ORPHANED: Failed to destroy #{sandbox.provider} resource #{sandbox.sprite_id} " <>
            "for sandbox #{sandbox.id} after #{attempt} attempts: #{inspect(reason)}. " <>
            "This service must be cleaned up manually or via orphan reconciliation."
        )
    end
  end
end
