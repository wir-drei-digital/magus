defmodule :"Elixir.Magus.Repo.Migrations.Sync isPinned snapshot" do
  @moduledoc """
  Syncs resource snapshot with existing schema.

  The is_pinned column was already added in migration 20260201023200.
  This migration exists only to update the Ash resource snapshot.
  """

  use Ecto.Migration

  def up do
    # Column already exists from manual migration 20260201023200
    :ok
  end

  def down do
    # No-op - column managed by manual migration
    :ok
  end
end
