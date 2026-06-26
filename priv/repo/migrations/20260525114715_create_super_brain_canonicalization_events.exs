defmodule Magus.Repo.Migrations.CreateSuperBrainCanonicalizationEvents do
  use Ecto.Migration

  def up do
    create table(:super_brain_canonicalization_events, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :graph_name, :string, null: false
      add :winner_id, :string, null: false
      add :loser_id, :string, null: false
      add :similarity, :float, null: false
      add :reason, :string, null: false
      add :extractor_version, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:super_brain_canonicalization_events, [:graph_name, :inserted_at])
  end

  def down do
    drop table(:super_brain_canonicalization_events)
  end
end
