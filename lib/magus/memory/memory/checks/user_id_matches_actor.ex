defmodule Magus.Memory.Memory.Checks.UserIdMatchesActor do
  @moduledoc """
  Check that verifies the user_id argument matches the current actor.

  Used for create actions where we can't use expr() filters because
  the record doesn't exist yet.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "user_id argument matches the current actor"
  end

  @impl true
  def match?(actor, %{changeset: changeset}, _opts) when not is_nil(actor) do
    user_id = Ash.Changeset.get_argument(changeset, :user_id)
    user_id == actor.id
  end

  def match?(_actor, _context, _opts), do: false
end
