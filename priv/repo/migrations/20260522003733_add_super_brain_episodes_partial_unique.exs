defmodule Magus.Repo.Migrations.AddSuperBrainEpisodesPartialUnique do
  @moduledoc """
  Closes D7: enforce append-only Episodes with `:supersede` provenance.

  The full unique index `super_brain_episodes_unique_resource_index`
  (dropped in the immediately-preceding migration) made re-extractions
  overwrite the prior row via Ash's `upsert?: true`. That destroyed
  provenance.

  This migration installs a PARTIAL unique index that allows arbitrarily
  many `:superseded` / `:failed` Episode rows per `(resource_type,
  resource_id)` while still guaranteeing at most one `:extracted` row.
  The extraction pipeline marks the prior `:extracted` row as
  `:superseded` and then inserts a fresh `:extracted` row, preserving
  the full extraction history for replay and debugging.

  Ash does not natively express partial unique constraints, so this is
  managed as raw SQL outside the Ash identity model. See
  `Magus.SuperBrain.Episode` for the corresponding comment.
  """

  use Ecto.Migration

  def up do
    create unique_index(:super_brain_episodes, [:resource_type, :resource_id],
             where: "status = 'extracted'",
             name: :super_brain_episodes_extracted_unique_index
           )
  end

  def down do
    drop_if_exists unique_index(:super_brain_episodes, [:resource_type, :resource_id],
                     name: :super_brain_episodes_extracted_unique_index
                   )
  end
end
