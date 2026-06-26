defmodule Magus.Repo.Migrations.AddUpdatedAtToJobRuns do
  @moduledoc """
  Adds updated_at timestamp to job_runs table to track when status was last modified.
  """

  use Ecto.Migration

  def up do
    alter table(:job_runs) do
      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    alter table(:job_runs) do
      remove :updated_at
    end
  end
end
