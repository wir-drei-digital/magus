defmodule Magus.Repo.Migrations.BackfillConversationGrants do
  use Ecto.Migration

  def up, do: Magus.Workspaces.Backfill.Conversations.run()
  def down, do: :ok
end
