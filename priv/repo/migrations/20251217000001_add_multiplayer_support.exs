defmodule Magus.Repo.Migrations.AddMultiplayerSupport do
  @moduledoc """
  Adds multiplayer support for conversations.

  Creates:
  - conversation_members: Join table for conversation participants
  - conversation_invite_links: Public/password-protected invite links
  - conversation_events: System events for join/leave/kick notifications

  Updates:
  - users: Adds display_name field
  - conversations: Adds is_multiplayer flag
  """
  use Ecto.Migration

  def change do
    # Add display_name to users
    alter table(:users) do
      add :display_name, :string
    end

    # Add is_multiplayer to conversations
    alter table(:conversations) do
      add :is_multiplayer, :boolean, null: false, default: false
    end

    # Create conversation_members table
    create table(:conversation_members, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :role, :string, null: false, default: "member"
      add :invited_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      add :is_muted, :boolean, null: false, default: false

      add :conversation_id,
          references(:conversations,
            column: :id,
            name: "conversation_members_conversation_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :user_id,
          references(:users,
            column: :id,
            name: "conversation_members_user_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :invited_by_id,
          references(:users,
            column: :id,
            name: "conversation_members_invited_by_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:conversation_members, [:conversation_id, :user_id],
             name: "conversation_members_unique_membership_index"
           )

    create index(:conversation_members, [:user_id])
    create index(:conversation_members, [:conversation_id])

    # Create conversation_invite_links table
    create table(:conversation_invite_links, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :token, :string, null: false
      add :password_hash, :string
      add :expires_at, :utc_datetime_usec
      add :max_uses, :integer
      add :uses_count, :integer, null: false, default: 0
      add :is_active, :boolean, null: false, default: true
      add :role, :string, null: false, default: "member"

      add :conversation_id,
          references(:conversations,
            column: :id,
            name: "conversation_invite_links_conversation_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :created_by_id,
          references(:users,
            column: :id,
            name: "conversation_invite_links_created_by_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:conversation_invite_links, [:token])
    create index(:conversation_invite_links, [:conversation_id])

    # Create conversation_events table
    create table(:conversation_events, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}

      add :conversation_id,
          references(:conversations,
            column: :id,
            name: "conversation_events_conversation_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :user_id,
          references(:users,
            column: :id,
            name: "conversation_events_user_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :target_user_id,
          references(:users,
            column: :id,
            name: "conversation_events_target_user_id_fkey",
            type: :uuid,
            on_delete: :nilify_all
          )

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:conversation_events, [:conversation_id])
    create index(:conversation_events, [:inserted_at])
  end
end
