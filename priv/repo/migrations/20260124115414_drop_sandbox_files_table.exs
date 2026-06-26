defmodule Magus.Repo.Migrations.DropSandboxFilesTable do
  @moduledoc """
  Drops the sandbox_files table.

  Files created by sandbox code execution are now stored in the Files domain
  instead of a separate sandbox-specific table.
  """

  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:sandbox_files, [:download_token],
                     name: "sandbox_files_unique_token_index"
                   )

    drop_if_exists constraint(:sandbox_files, "sandbox_files_sandbox_id_fkey")
    drop_if_exists constraint(:sandbox_files, "sandbox_files_execution_id_fkey")

    drop_if_exists table(:sandbox_files)
  end

  def down do
    create table(:sandbox_files, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :filename, :text, null: false
      add :path, :text, null: false
      add :size_bytes, :bigint
      add :mime_type, :text, default: "application/octet-stream"
      add :download_token, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :sandbox_id,
          references(:sandboxes,
            column: :id,
            name: "sandbox_files_sandbox_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :execution_id,
          references(:sandbox_executions,
            column: :id,
            name: "sandbox_files_execution_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create unique_index(:sandbox_files, [:download_token],
             name: "sandbox_files_unique_token_index"
           )
  end
end
