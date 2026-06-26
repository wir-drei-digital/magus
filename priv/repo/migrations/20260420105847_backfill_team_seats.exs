defmodule Magus.Repo.Migrations.BackfillTeamSeats do
  use Ecto.Migration

  @defaults %{
    "free" => 1,
    "starter" => 5,
    "pro" => 25,
    "enterprise" => nil
  }

  def up do
    for {key, seats} <- @defaults do
      value = if is_nil(seats), do: "NULL", else: Integer.to_string(seats)
      execute("UPDATE usage_plans SET team_seats = #{value} WHERE key = '#{key}'")
    end
  end

  def down do
    execute("UPDATE usage_plans SET team_seats = NULL")
  end
end
