defmodule Magus.Repo.Migrations.RemoveLegacyCreditFields do
  use Ecto.Migration

  def change do
    alter table(:usage_plans) do
      remove :daily_credits, :bigint
    end

    alter table(:user_usage_overrides) do
      remove :bonus_daily_credits, :bigint
    end

    alter table(:message_usages) do
      remove :credits_consumed, :bigint
    end
  end
end
