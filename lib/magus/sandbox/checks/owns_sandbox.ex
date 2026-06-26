defmodule Magus.Sandbox.Checks.OwnsSandbox do
  @moduledoc """
  Policy check that verifies the actor owns the sandbox specified by sandbox_id argument.

  This prevents users from creating executions for sandboxes they don't own.
  """

  use Ash.Policy.SimpleCheck

  require Logger

  @impl true
  def describe(_opts) do
    "actor owns the sandbox"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: changeset}, _opts) do
    # sandbox_id might be an argument or attribute depending on the action
    sandbox_id =
      Ash.Changeset.get_argument(changeset, :sandbox_id) ||
        Ash.Changeset.get_attribute(changeset, :sandbox_id)

    if is_nil(sandbox_id) do
      false
    else
      # Use authorize?: false since we're doing explicit ownership verification
      # This avoids confusing authorization errors from nested policy checks
      case Magus.Sandbox.get_sandbox(sandbox_id, authorize?: false, load: [:conversation]) do
        {:ok, sandbox} ->
          # Defensive check in case conversation relationship failed to load
          sandbox.conversation && sandbox.conversation.user_id == actor.id

        {:error, %Ash.Error.Query.NotFound{}} ->
          false

        {:error, reason} ->
          # Log non-NotFound errors to aid debugging transient failures
          Logger.warning("OwnsSandbox check failed due to database error",
            sandbox_id: sandbox_id,
            actor_id: actor.id,
            error: inspect(reason)
          )

          false
      end
    end
  end

  def match?(_actor, _context, _opts), do: false
end
