defmodule Magus.Repo.Migrations.ExpandDocumentTypes do
  @moduledoc """
  Expands document type support by migrating :pdf to :document
  and adding support for :email type.

  This enables ExtractousEx to handle Microsoft Office, OpenDocument,
  EPUB, and email file formats in addition to PDF.
  """

  use Ecto.Migration

  def up do
    # Update existing :pdf records to :document
    execute "UPDATE memory_resources SET type = 'document' WHERE type = 'pdf'"
  end

  def down do
    # Revert :document back to :pdf
    execute "UPDATE memory_resources SET type = 'pdf' WHERE type = 'document'"
    # Remove any :email records (they didn't exist before)
    execute "DELETE FROM memory_resources WHERE type = 'email'"
  end
end
