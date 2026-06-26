defmodule Magus.Drafts.Draft.Changes.ConvertToProsemirror do
  @moduledoc """
  Converts a markdown string argument to ProseMirror JSON and sets it
  as the `content` attribute.

  Used on `create` and `update_content` actions where the caller provides
  markdown (e.g. from the AI agent) and we need to store structured JSON.
  """

  use Ash.Resource.Change

  alias Magus.Drafts.ProseMirrorConverter

  @impl true
  def change(changeset, _opts, _context) do
    markdown = Ash.Changeset.get_argument(changeset, :content) || ""

    case ProseMirrorConverter.from_markdown(markdown) do
      {:ok, json_doc} ->
        Ash.Changeset.force_change_attribute(changeset, :content, json_doc)

      {:error, _reason} ->
        # Fallback: store as a paragraph with the raw text
        fallback = %{
          "type" => "doc",
          "content" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => markdown}]}
          ]
        }

        Ash.Changeset.force_change_attribute(changeset, :content, fallback)
    end
  end
end
