defmodule Magus.Sandbox.Sandbox.Changes.Provision do
  @moduledoc """
  Provisions a new sandbox via the configured provider.

  This change:
  1. Reads the provider from the changeset (set during :create action)
  2. Calls the provider's create_sandbox API
  3. Stores the sandbox_id (sprite_id) and url on the sandbox

  Note: Packages are installed on-demand via the install_packages tool for faster sandbox creation.
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Sandbox.Provider

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      sandbox = changeset.data
      provider = Ash.Changeset.get_attribute(changeset, :provider) || Provider.active_provider()
      client = Provider.client_for(%{provider: provider})
      start_time = System.monotonic_time()

      case do_provision(client) do
        {:ok, sandbox_id, url} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:magus, :sandbox, :provision],
            %{duration: duration},
            %{sandbox_id: sandbox.id, sprite_id: sandbox_id}
          )

          changeset
          |> Ash.Changeset.force_change_attribute(:sprite_id, sandbox_id)
          |> Ash.Changeset.force_change_attribute(:sprite_url, url)

        {:error, sandbox_id, :not_configured} ->
          maybe_cleanup(client, sandbox_id)

          Logger.warning("Sandbox provider not configured")

          Ash.Changeset.add_error(changeset,
            field: :sprite_id,
            message: "Code execution is not configured."
          )

        {:error, sandbox_id, {:api_error, status, _body}} when status in [401, 403] ->
          maybe_cleanup(client, sandbox_id)
          Logger.error("Sandbox API authentication failed (status #{status})")

          Ash.Changeset.add_error(changeset,
            field: :sprite_id,
            message: "Code execution authentication failed."
          )

        {:error, sandbox_id, {:api_error, 404, _body}} ->
          maybe_cleanup(client, sandbox_id)
          Logger.error("Sandbox API endpoint not found.")

          Ash.Changeset.add_error(changeset,
            field: :sprite_id,
            message: "Code execution service unavailable."
          )

        {:error, sandbox_id, reason} ->
          maybe_cleanup(client, sandbox_id)
          Logger.error("Failed to provision sandbox: #{inspect(reason)}")

          Ash.Changeset.add_error(changeset,
            field: :sprite_id,
            message: "Failed to provision sandbox: #{inspect(reason)}"
          )
      end
    end)
  end

  # Cleanup a partially-created sandbox on failure.
  # Uses apply/3 to avoid compile-time warnings about not-yet-compiled provider modules.
  defp maybe_cleanup(_client, nil), do: :ok
  defp maybe_cleanup(client, sandbox_id), do: apply(client, :destroy, [sandbox_id])

  # Orchestrate the full provisioning sequence:
  # 1. Create sandbox (sprite/daytona)
  # 2. Network policy is handled via create_sandbox option
  defp do_provision(client) do
    case apply(client, :create_sandbox, [[network_policy: true]]) do
      {:ok, %{sandbox_id: sandbox_id, url: url}} ->
        {:ok, sandbox_id, url}

      {:error, {:network_policy_failed, reason}} ->
        # Network policy setup failed after sandbox was created —
        # the sandbox_id was already cleaned up by create_sandbox
        {:error, nil, {:network_policy_failed, reason}}

      {:error, :not_configured} ->
        {:error, nil, :not_configured}

      {:error, reason} ->
        {:error, nil, reason}
    end
  rescue
    e ->
      Logger.error("Unexpected error during provisioning: #{Exception.message(e)}")
      {:error, nil, {:unexpected_error, Exception.message(e)}}
  end
end
