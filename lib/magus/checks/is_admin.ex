defmodule Magus.Checks.IsAdmin do
  @moduledoc """
  Check if the actor is an admin user.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is an admin"
  end

  @impl true
  def match?(actor, _context, _opts) do
    case actor do
      %{is_admin: true} -> true
      _ -> false
    end
  end
end
