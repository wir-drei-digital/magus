defmodule Magus.Chat.Changes.UnlinkCompanions do
  @moduledoc """
  After-action sweep: drops every `Magus.Chat.ConversationCompanion` row
  pointing at the destroyed resource, leaving the linked conversations
  intact (per the companion design's drop-link-on-resource-delete rule).

  Use on destroy/soft_delete actions:

      change {Magus.Chat.Changes.UnlinkCompanions, resource_type: :file}
      change {Magus.Chat.Changes.UnlinkCompanions, resource_type: :brain_page}
  """

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    resource_type = Keyword.fetch!(opts, :resource_type)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      case Magus.Chat.unlink_companion_for_resource(resource_type, record.id) do
        :ok -> {:ok, record}
        {:error, reason} -> {:error, reason}
      end
    end)
  end
end
