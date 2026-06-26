defmodule Magus.Repo.Migrations.AddIsPinnedToMemories do
  @moduledoc """
  Add is_pinned attribute to memories.

  Pinned memories are always included in the conversation context.
  Max 3 memories can be pinned per conversation (local) or per user (global).
  """
  use Ecto.Migration

  def change do
    alter table(:memories) do
      add :is_pinned, :boolean, null: false, default: false
    end

    # Index for quickly fetching pinned local memories
    create index(:memories, [:conversation_id, :is_pinned],
             where: "is_active = true AND scope = 'local' AND is_pinned = true",
             name: :memories_pinned_local
           )

    # Index for quickly fetching pinned global memories
    create index(:memories, [:user_id, :is_pinned],
             where: "is_active = true AND scope = 'global' AND is_pinned = true",
             name: :memories_pinned_global
           )
  end
end
