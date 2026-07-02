defmodule Magus.Chat.Conversation.Changes.RecordSkillApproval do
  @moduledoc "Appends a skill id to approved_skill_ids without duplicates."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    id = Ash.Changeset.get_argument(changeset, :skill_id)
    existing = Ash.Changeset.get_attribute(changeset, :approved_skill_ids) || []
    Ash.Changeset.change_attribute(changeset, :approved_skill_ids, Enum.uniq([id | existing]))
  end
end
