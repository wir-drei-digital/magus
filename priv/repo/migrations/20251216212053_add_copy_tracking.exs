defmodule Magus.Repo.Migrations.AddCopyTracking do
  @moduledoc """
  Adds copy tracking fields to blocks and stacks.
  """
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :copied_from_id,
          references(:blocks,
            column: :id,
            name: "blocks_copied_from_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :copy_count, :integer, default: 0, null: false
    end

    alter table(:stacks) do
      add :copied_from_id,
          references(:stacks,
            column: :id,
            name: "stacks_copied_from_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :copy_count, :integer, default: 0, null: false
    end

    create index(:blocks, [:copied_from_id])
    create index(:stacks, [:copied_from_id])
  end
end
