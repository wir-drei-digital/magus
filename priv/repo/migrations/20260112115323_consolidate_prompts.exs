defmodule Magus.Repo.Migrations.ConsolidatePrompts do
  @moduledoc """
  Consolidates personas, prompts, and flows into a single prompts resource.

  - Personas become prompts with type :system
  - Existing prompts (persona, task, format, context) become type :user
  - Flows are removed entirely
  - Conversation.active_persona_id becomes system_prompt_id
  """
  use Ecto.Migration

  def up do
    # Step 1: Add new columns to prompts table
    alter table(:prompts) do
      add :chat_mode, :string
      add :model_id, references(:models, type: :uuid, on_delete: :nilify_all)
    end

    create index(:prompts, [:model_id])

    # Step 2: Create temporary mapping table
    execute """
    CREATE TEMP TABLE persona_prompt_mapping (
      persona_id UUID PRIMARY KEY,
      new_prompt_id UUID NOT NULL
    )
    """

    # Step 3: Migrate personas to prompts with type 'system'
    execute """
    WITH inserted AS (
      INSERT INTO prompts (id, name, content, type, chat_mode, model_id, user_id,
                          is_public, published_at, is_highlighted, copy_count,
                          metadata, variables, inserted_at, updated_at)
      SELECT
        gen_random_uuid(),
        name,
        system_prompt,
        'system',
        chat_mode::text,
        model_id,
        user_id,
        is_public,
        published_at,
        is_highlighted,
        copy_count,
        '{}',
        '{}',
        inserted_at,
        updated_at
      FROM personas
      RETURNING id, name, user_id, inserted_at
    )
    INSERT INTO persona_prompt_mapping (persona_id, new_prompt_id)
    SELECT p.id, i.id
    FROM personas p
    JOIN inserted i ON i.name = p.name
                    AND i.user_id = p.user_id
                    AND i.inserted_at = p.inserted_at
    """

    # Step 4: Migrate persona tags to prompt tags
    execute """
    INSERT INTO prompt_tags (id, prompt_id, tag_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), m.new_prompt_id, pt.tag_id, pt.inserted_at, pt.updated_at
    FROM persona_tags pt
    JOIN persona_prompt_mapping m ON pt.persona_id = m.persona_id
    ON CONFLICT DO NOTHING
    """

    # Step 5: Migrate persona favorites to prompt favorites
    execute """
    INSERT INTO prompt_favorites (id, prompt_id, user_id, inserted_at)
    SELECT gen_random_uuid(), m.new_prompt_id, pf.user_id, pf.inserted_at
    FROM persona_favorites pf
    JOIN persona_prompt_mapping m ON pf.persona_id = m.persona_id
    ON CONFLICT DO NOTHING
    """

    # Step 6: Add system_prompt_id column to conversations
    alter table(:conversations) do
      add :system_prompt_id, references(:prompts, type: :uuid, on_delete: :nilify_all)
    end

    create index(:conversations, [:system_prompt_id])

    # Step 7: Update conversations with mapped system_prompt_id
    execute """
    UPDATE conversations c
    SET system_prompt_id = m.new_prompt_id
    FROM persona_prompt_mapping m
    WHERE c.active_persona_id = m.persona_id
    """

    # Step 8: Drop active_persona_id column
    alter table(:conversations) do
      remove :active_persona_id
    end

    # Step 9: Update existing prompt types to 'user'
    execute """
    UPDATE prompts
    SET type = 'user'
    WHERE type IN ('persona', 'task', 'format', 'context', 'query', 'command')
    """

    # Step 10: Drop persona tables (in order of FK dependencies)
    drop_if_exists table(:persona_prompts)
    drop_if_exists table(:persona_favorites)
    drop_if_exists table(:persona_tags)
    drop_if_exists table(:personas)

    # Step 11: Drop flow tables (in order of FK dependencies)
    drop_if_exists table(:flow_favorites)
    drop_if_exists table(:flow_tags)
    drop_if_exists table(:flows_prompts)
    drop_if_exists table(:flows)

    # Step 12: Drop the temporary mapping table
    execute "DROP TABLE IF EXISTS persona_prompt_mapping"
  end

  def down do
    # Recreate personas table
    create table(:personas, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :system_prompt, :text, null: false
      add :chat_mode, :string
      add :is_public, :boolean, default: false
      add :published_at, :utc_datetime_usec
      add :is_highlighted, :boolean, default: false
      add :copy_count, :bigint, default: 0
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :model_id, references(:models, type: :uuid, on_delete: :nilify_all)
      add :copied_from_id, references(:personas, type: :uuid, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:personas, [:user_id])
    create index(:personas, [:is_public])
    create index(:personas, [:is_highlighted])
    create index(:personas, [:copied_from_id])

    # Recreate persona_tags
    create table(:persona_tags, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :persona_id, references(:personas, type: :uuid, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, type: :uuid, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:persona_tags, [:persona_id, :tag_id])

    # Recreate persona_favorites
    create table(:persona_favorites, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :persona_id, references(:personas, type: :uuid, on_delete: :delete_all), null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:persona_favorites, [:user_id, :persona_id])

    # Recreate persona_prompts
    create table(:persona_prompts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :persona_id, references(:personas, type: :uuid, on_delete: :delete_all), null: false
      add :prompt_id, references(:prompts, type: :uuid, on_delete: :delete_all), null: false
      add :position, :bigint, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:persona_prompts, [:persona_id, :prompt_id])

    # Recreate flows table
    create table(:flows, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :description, :text
      add :is_public, :boolean, default: false
      add :published_at, :utc_datetime_usec
      add :is_highlighted, :boolean, default: false
      add :copy_count, :bigint, default: 0
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :copied_from_id, references(:flows, type: :uuid, on_delete: :nilify_all)
      timestamps(type: :utc_datetime_usec)
    end

    create index(:flows, [:user_id])
    create index(:flows, [:is_public])
    create index(:flows, [:is_highlighted])
    create index(:flows, [:copied_from_id])

    # Recreate flows_prompts
    create table(:flows_prompts, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :flow_id, references(:flows, type: :uuid, on_delete: :delete_all), null: false
      add :prompt_id, references(:prompts, type: :uuid, on_delete: :delete_all), null: false
      add :position, :bigint, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flows_prompts, [:flow_id, :prompt_id])

    # Recreate flow_tags
    create table(:flow_tags, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :flow_id, references(:flows, type: :uuid, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, type: :uuid, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flow_tags, [:flow_id, :tag_id])

    # Recreate flow_favorites
    create table(:flow_favorites, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :flow_id, references(:flows, type: :uuid, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:flow_favorites, [:user_id, :flow_id])

    # Add active_persona_id back to conversations
    alter table(:conversations) do
      add :active_persona_id, references(:personas, type: :uuid, on_delete: :nilify_all)
    end

    # Remove system_prompt_id from conversations
    alter table(:conversations) do
      remove :system_prompt_id
    end

    # Remove new columns from prompts
    alter table(:prompts) do
      remove :chat_mode
      remove :model_id
    end

    # Note: Data migration back is not implemented - this is a destructive migration
    # Restoring original prompt types would require manual intervention
  end
end
