defmodule Magus.Repo.Migrations.DropWorkspaceBillingColumns do
  use Ecto.Migration

  def up do
    alter table(:workspaces) do
      remove :plan_id
      remove :stripe_customer_id
      remove :stripe_subscription_id
      remove :base_seats
      remove :max_seats
    end
  end

  def down do
    alter table(:workspaces) do
      add :plan_id, references(:usage_plans, type: :uuid, on_delete: :nilify_all)
      add :stripe_customer_id, :string
      add :stripe_subscription_id, :string
      add :base_seats, :integer, null: false, default: 5
      add :max_seats, :integer
    end
  end
end
