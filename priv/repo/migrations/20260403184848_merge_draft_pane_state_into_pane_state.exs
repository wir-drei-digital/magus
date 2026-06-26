defmodule Magus.Repo.Migrations.MergeDraftPaneStateIntoPaneState do
  use Ecto.Migration

  def up do
    # Migrate open draft pane states to the generic pane_states table.
    # Only rows where pane_open = true represent an active state worth preserving.
    # Use DISTINCT ON to pick one draft per (conversation_id, user_id),
    # preferring the most recently updated. Without this, a user with
    # multiple open drafts in the same conversation causes a
    # cardinality_violation on the upsert.
    execute """
    INSERT INTO pane_states (id, pane_type, resource_id, conversation_id, user_id, inserted_at, updated_at)
    SELECT
      uuid_generate_v7(),
      'draft',
      dps.draft_id,
      d.conversation_id,
      dps.user_id,
      dps.inserted_at,
      dps.updated_at
    FROM (
      SELECT DISTINCT ON (d2.conversation_id, dps2.user_id)
        dps2.*
      FROM draft_pane_states dps2
      JOIN drafts d2 ON d2.id = dps2.draft_id
      WHERE dps2.pane_open = true
      ORDER BY d2.conversation_id, dps2.user_id, dps2.updated_at DESC
    ) dps
    JOIN drafts d ON d.id = dps.draft_id
    ON CONFLICT (conversation_id, user_id) DO UPDATE SET
      pane_type = 'draft',
      resource_id = EXCLUDED.resource_id,
      updated_at = EXCLUDED.updated_at
    """

    drop table(:draft_pane_states)
  end

  def down do
    create table(:draft_pane_states, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :pane_open, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :draft_id,
          references(:drafts,
            column: :id,
            name: "draft_pane_states_draft_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :user_id,
          references(:users,
            column: :id,
            name: "draft_pane_states_user_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false
    end

    create unique_index(:draft_pane_states, [:draft_id, :user_id],
             name: "draft_pane_states_unique_draft_user_index"
           )
  end
end
