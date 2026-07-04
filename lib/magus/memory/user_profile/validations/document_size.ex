defmodule Magus.Memory.UserProfile.Validations.DocumentSize do
  @moduledoc """
  Hard cap on the profile document. The distiller targets 3200 chars
  (~800 tokens); this is the resource-level backstop at 4000 chars.
  """
  use Ash.Resource.Validation

  @max_chars 4000

  @impl true
  def validate(changeset, _opts, _context) do
    document = Ash.Changeset.get_attribute(changeset, :document) || ""

    if String.length(document) <= @max_chars do
      :ok
    else
      {:error, field: :document, message: "must be at most #{@max_chars} characters"}
    end
  end
end
