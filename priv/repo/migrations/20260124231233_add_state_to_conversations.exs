defmodule Magus.Repo.Migrations.AddStateToConversations do
  @moduledoc """
  Adds a state field to conversations to track agent activity state.

  States:
  - idle: No activity (default)
  - thinking: AI is preparing response (before streaming starts)
  - processing: AI is streaming text
  - tool_call: AI is executing tools
  - waiting: Waiting for external service (video generation polling)
  """

  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :state, :text, null: false, default: "idle"
    end

    # Partial index for efficiently finding non-idle conversations
    # Useful for monitoring active conversations or cleanup tasks
    create index(:conversations, [:state],
             where: "state != 'idle'",
             name: :conversations_active_state_index
           )
  end
end
