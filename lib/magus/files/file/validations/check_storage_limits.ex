defmodule Magus.Files.File.Validations.CheckStorageLimits do
  @moduledoc """
  Validates that a file upload doesn't exceed the user's storage limits.

  Checks:
  - File size doesn't exceed max_upload_bytes
  - Adding this file won't exceed storage quota
  - User isn't already over their storage quota (overage state)
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    file_size = Ash.Changeset.get_attribute(changeset, :file_size)
    user = context.actor

    case user do
      nil ->
        # No actor - skip validation (will be handled by authorization)
        :ok

      %Magus.Agents.Support.AiAgent{} ->
        # AI agents bypass storage limits
        :ok

      user ->
        check_limits(user, file_size)
    end
  end

  defp check_limits(user, file_size) do
    alias Magus.Usage.PolicyEnforcer

    case PolicyEnforcer.check_file_upload(user, file_size) do
      {:ok, :allowed} ->
        :ok

      {:error, %Magus.Usage.PolicyError{} = error} ->
        {:error, field: :file_size, message: Magus.Usage.PolicyErrorMessage.message(error)}
    end
  end
end
