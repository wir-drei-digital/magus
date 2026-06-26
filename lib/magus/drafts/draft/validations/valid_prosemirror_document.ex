defmodule Magus.Drafts.Draft.Validations.ValidProsemirrorDocument do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :content_json) do
      %{"type" => "doc", "content" => nodes} when is_list(nodes) -> :ok
      _ -> {:error, field: :content_json, message: "must be a valid ProseMirror document"}
    end
  end
end
