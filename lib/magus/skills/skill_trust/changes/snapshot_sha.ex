defmodule Magus.Skills.SkillTrust.Changes.SnapshotSha do
  @moduledoc "Snapshots the skill's current bundle_sha at trust-grant time."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Resolve the skill's current sha in a before_action (single write, no
    # second update action needed) and set it on the changeset.
    Ash.Changeset.before_action(changeset, fn cs ->
      skill_id = Ash.Changeset.get_argument(cs, :skill_id)

      case Magus.Skills.get_skill(skill_id, authorize?: false) do
        {:ok, skill} ->
          Ash.Changeset.change_attribute(cs, :bundle_sha_at_grant, skill.bundle_sha)

        _ ->
          cs
      end
    end)
  end
end
