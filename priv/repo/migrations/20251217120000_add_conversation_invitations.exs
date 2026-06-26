defmodule Magus.Repo.Migrations.AddConversationInvitations do
  @moduledoc """
  Adds email-based invitations and visibility setting for multiplayer conversations.

  Changes:
  - conversations: Adds visibility field (invite_only vs public)
  - conversation_invitations: New table for email-based invites
  """
  use Ecto.Migration

  def change do
    # Add visibility to conversations
    alter table(:conversations) do
      add :visibility, :string, null: false, default: "invite_only"
    end

    # Create conversation_invitations table
    create table(:conversation_invitations, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :email, :citext, null: false
      add :token, :string, null: false
      add :role, :string, null: false, default: "member"
      add :accepted_at, :utc_datetime_usec

      add :conversation_id,
          references(:conversations,
            column: :id,
            name: "conversation_invitations_conversation_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :invited_by_id,
          references(:users,
            column: :id,
            name: "conversation_invitations_invited_by_id_fkey",
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

    create unique_index(:conversation_invitations, [:token])
    create unique_index(:conversation_invitations, [:conversation_id, :email])
    create index(:conversation_invitations, [:conversation_id])
    create index(:conversation_invitations, [:email])
  end
end
