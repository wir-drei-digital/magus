defmodule Magus.Repo.Migrations.AddFeatureUsageEventsIndex do
  use Ecto.Migration

  def change do
    create index(:feature_usage_events, [:user_id, :feature])
  end
end
