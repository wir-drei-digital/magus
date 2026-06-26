defmodule Magus.Checks.OwnsJob do
  @moduledoc """
  Policy check that authorizes users who own the job being referenced.

  For create actions on resources that reference a job (like NotificationPreference),
  this check looks up the job_id argument and verifies the actor owns that job.

  For update/destroy actions, it checks if the record's associated job is owned by the actor.

  Note: For read actions, use expr-based policies instead as this check returns false.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor owns the referenced job"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{action: %{type: :create}} = changeset}, _opts) do
    # For creates, check the job_id argument
    job_id = Ash.Changeset.get_argument(changeset, :job_id)
    owns_job?(actor, job_id)
  end

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    # For updates/destroys, check the existing record's job relationship
    case changeset.data do
      %{job_id: job_id} when not is_nil(job_id) ->
        owns_job?(actor, job_id)

      _ ->
        # Fallback to checking argument if data doesn't have job_id
        job_id = Ash.Changeset.get_argument(changeset, :job_id)
        owns_job?(actor, job_id)
    end
  end

  def match?(_actor, %{query: %Ash.Query{} = _query}, _opts) do
    # This check is not designed for read actions.
    # For reads, use expr-based policies with relationship filters.
    false
  end

  def match?(_actor, _context, _opts), do: false

  @spec owns_job?(struct(), String.t() | nil) :: boolean()
  defp owns_job?(_actor, nil), do: false

  defp owns_job?(actor, job_id) do
    # authorize?: false is intentional here to prevent circular authorization.
    # This check is called during policy evaluation, and authorizing the job lookup
    # would trigger another policy evaluation, leading to infinite recursion.
    # The ownership check itself provides the authorization - if the actor owns
    # the job, the original action is authorized.
    case Magus.Workflows.get_job(job_id, authorize?: false) do
      {:ok, job} -> job.user_id == actor.id
      {:error, _} -> false
    end
  end
end
