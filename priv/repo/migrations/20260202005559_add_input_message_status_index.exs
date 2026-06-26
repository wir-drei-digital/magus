defmodule Magus.Repo.Migrations.AddInputMessageStatusIndex do
  @moduledoc """
  Adds index on integration_input_messages.status for better query performance
  when listing pending messages.
  """
  use Ecto.Migration

  def change do
    create index(:integration_input_messages, [:status])
  end
end
