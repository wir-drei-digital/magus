defmodule Magus.Checks.RelatesUserToActor do
  @moduledoc """
  Policy check that validates the user_id being set matches the actor's id.

  This is used for create actions where we can't use expr() since
  data doesn't exist yet, and relates_to_actor_via generates filters
  that also can't be evaluated during creates.

  This check looks at the user_id argument (or attribute change) and
  verifies it matches the actor's id.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "user_id matches actor id"
  end

  @impl true
  def match?(%{id: actor_id} = _actor, context, _opts) when not is_nil(actor_id) do
    # Extract changeset from context - it may be the changeset directly
    # or wrapped in an authorizer struct
    changeset = extract_changeset(context)

    case changeset do
      %Ash.Changeset{} ->
        # Get user_id from argument first (for create actions), then from attributes
        user_id =
          case Ash.Changeset.fetch_argument(changeset, :user_id) do
            {:ok, value} -> value
            :error -> Ash.Changeset.get_attribute(changeset, :user_id)
          end

        to_string(user_id) == to_string(actor_id)

      _ ->
        false
    end
  end

  def match?(_actor, _context, _opts), do: false

  # Extract changeset from various context types
  defp extract_changeset(%Ash.Changeset{} = changeset), do: changeset

  defp extract_changeset(%{subject: %Ash.Changeset{} = changeset}), do: changeset

  defp extract_changeset(%{changeset: %Ash.Changeset{} = changeset}), do: changeset

  defp extract_changeset(_), do: nil
end
