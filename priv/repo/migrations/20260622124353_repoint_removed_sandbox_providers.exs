defmodule Magus.Repo.Migrations.RepointRemovedSandboxProviders do
  @moduledoc """
  Data migration for the open-core split: the `:northflank` and `:modal`
  sandbox adapters were removed (only `:sprites`/`:daytona`/`:test` remain).

  The `sandboxes.provider` column is plain text but the Ash resource now
  constrains it to the surviving values, and `Ash.Type.Atom` reads stored
  values via `String.to_existing_atom/1`. Any leftover row pinned to a removed
  provider would therefore fail to load, so repoint such rows to `:daytona`
  (the new default). These rows are almost always terminated sandboxes; an
  active one simply fails-and-reprovisions on next use, which is expected
  during a provider migration.

  Irreversible by design: the removed providers no longer have adapters to
  point back to.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE sandboxes
    SET provider = 'daytona'
    WHERE provider IN ('northflank', 'modal')
    """)
  end

  def down do
    :ok
  end
end
