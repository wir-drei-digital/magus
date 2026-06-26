defmodule Magus.Drafts.Draft.Changes.RestoreVersion do
  @moduledoc """
  Restores draft content and title from a paper trail version snapshot.

  Validates that the version belongs to the draft being restored to prevent
  cross-draft data leaks.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      version_id = Ash.Changeset.get_argument(changeset, :version_id)

      case Ash.get(Magus.Drafts.Draft.Version, version_id, authorize?: false) do
        {:ok, version} ->
          if version.version_source_id == changeset.data.id do
            # Paper trail changes are stored as JSON — keys are always strings after DB round-trip
            # Content is now a map (ProseMirror JSON), which paper trail preserves as-is
            content = version.changes["content"] || changeset.data.content

            changeset
            |> Ash.Changeset.force_change_attribute(:content, content)
            |> Ash.Changeset.force_change_attribute(
              :title,
              version.changes["title"] || changeset.data.title
            )
          else
            Ash.Changeset.add_error(changeset,
              field: :version_id,
              message: "version does not belong to this draft"
            )
          end

        {:error, _} ->
          Ash.Changeset.add_error(changeset, field: :version_id, message: "version not found")
      end
    end)
  end
end
