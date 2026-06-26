defmodule Magus.Models.RoleAssignment.Validations.KnownRole do
  @moduledoc "Role string must match a key in the Roles registry."

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :role) do
      nil ->
        :ok

      role ->
        known = Enum.map(Magus.Models.Roles.all(), &Atom.to_string(&1.key))

        if role in known do
          :ok
        else
          {:error, field: :role, message: "is not a known model role"}
        end
    end
  end
end
