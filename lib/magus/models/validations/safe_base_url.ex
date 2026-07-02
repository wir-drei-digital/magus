defmodule Magus.Models.Validations.SafeBaseUrl do
  @moduledoc "Applies SSRF validation to base_url on owned-provider actions."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :base_url) do
      nil ->
        :ok

      "" ->
        :ok

      url ->
        case Magus.Models.BaseUrlValidator.validate(url) do
          :ok -> :ok
          {:error, msg} -> {:error, field: :base_url, message: msg}
        end
    end
  end
end
