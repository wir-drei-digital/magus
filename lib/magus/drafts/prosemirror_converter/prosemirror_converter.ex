defmodule Magus.Drafts.ProseMirrorConverter do
  @moduledoc "Deprecated alias. See `Magus.Markdown.ProseMirror`."
  defdelegate from_markdown(markdown), to: Magus.Markdown.ProseMirror
  defdelegate to_markdown(doc), to: Magus.Markdown.ProseMirror
  defdelegate to_plain_text(doc), to: Magus.Markdown.ProseMirror
  defdelegate default_doc(), to: Magus.Markdown.ProseMirror
end
