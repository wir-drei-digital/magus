defmodule Magus.Drafts.Draft.Changes.ReplaceText do
  @moduledoc """
  Replaces text in the draft's ProseMirror JSON content.

  Delegates to `NodeReplacer.replace_text/4` which converts the JSON to
  a deterministic markdown representation, performs string matching/replacement,
  then converts the result back to JSON.

  Algorithm:
  - Convert JSON content to markdown via `to_markdown/1`
  - Find all occurrences of `old_text` in the markdown via `:binary.matches/2`
  - 0 matches → error "text not found in document"
  - 1 match → replace directly
  - N matches + `hint_line` → pick the occurrence closest to `hint_line`
  - N matches + no `hint_line` → error "found N occurrences; provide hint_line"
  """

  use Ash.Resource.Change

  alias Magus.Drafts.ProseMirrorConverter.NodeReplacer

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      old_text = Ash.Changeset.get_argument(changeset, :old_text)
      new_text = Ash.Changeset.get_argument(changeset, :new_text)
      hint_line = Ash.Changeset.get_argument(changeset, :hint_line)

      content =
        changeset.data.content || %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}

      if old_text == "" do
        Ash.Changeset.add_error(changeset,
          field: :old_text,
          message: "must not be empty"
        )
      else
        case NodeReplacer.replace_text(content, old_text, new_text, hint_line) do
          {:ok, new_content} ->
            Ash.Changeset.force_change_attribute(changeset, :content, new_content)

          {:error, message} ->
            Ash.Changeset.add_error(changeset,
              field: :old_text,
              message: message
            )
        end
      end
    end)
  end
end
