defmodule Magus.Agents.CustomAgent.Validations.HandleFormat do
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :handle) do
      nil ->
        :ok

      handle ->
        if Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, handle) do
          :ok
        else
          {:error, field: :handle, message: "must be lowercase alphanumeric with hyphens"}
        end
    end
  end
end
