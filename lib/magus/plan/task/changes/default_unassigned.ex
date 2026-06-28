defmodule Magus.Plan.Task.Changes.DefaultUnassigned do
  @moduledoc """
  Plan tasks start unassigned.

  The `assigned_to_agent` attribute carries a `default "assistant"`, which
  `set_defaults/3` applies BEFORE action changes run. By that point
  `get_argument_or_attribute/2` already sees "assistant", so we instead detect
  whether the *caller* supplied a value (via the raw casted params) and force
  nil only when they did not.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if caller_supplied?(changeset, :assigned_to_agent) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :assigned_to_agent, nil)
    end
  end

  # Whether the caller explicitly provided `attribute` in the action's params
  # (as opposed to it being filled in by an attribute default). Handles both
  # atom- and string-keyed params so HTTP/JSON callers behave the same.
  defp caller_supplied?(changeset, attribute) do
    params = changeset.params || %{}
    Map.has_key?(params, attribute) or Map.has_key?(params, to_string(attribute))
  end
end
