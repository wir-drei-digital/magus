defmodule Magus.Sandbox.Sandbox.Changes.Suspend do
  @moduledoc """
  Suspends an active sandbox.

  Calls the provider's `checkpoint/1` which either snapshots state
  (returning a checkpoint_id) or is a no-op for providers that
  auto-hibernate (e.g. Sprites).
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Sandbox.Provider

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      sandbox = changeset.data
      sprite_id = sandbox.sprite_id

      if is_nil(sprite_id) do
        Ash.Changeset.add_error(changeset,
          field: :sprite_id,
          message: "Cannot suspend sandbox without sprite_id"
        )
      else
        client = Provider.client_for(sandbox)
        start_time = System.monotonic_time()

        case apply(client, :checkpoint, [sprite_id]) do
          {:ok, checkpoint_id} ->
            emit_telemetry(start_time, sandbox.id, sprite_id)

            changeset
            |> Ash.Changeset.force_change_attribute(:checkpoint_id, checkpoint_id)
            |> Ash.Changeset.force_change_attribute(:service_port, nil)

          :ok ->
            emit_telemetry(start_time, sandbox.id, sprite_id)
            Ash.Changeset.force_change_attribute(changeset, :service_port, nil)

          {:error, reason} when reason in [:not_found, :not_exists] ->
            Logger.warning("Sandbox #{sprite_id} not found during suspend, aborting suspend")

            Ash.Changeset.add_error(changeset,
              field: :sprite_id,
              message: "Sandbox not found at provider — will be cleaned up on next access"
            )

          {:error, {:api_error, 404, _}} ->
            Logger.warning(
              "Sandbox #{sprite_id} not found during suspend (404), aborting suspend"
            )

            Ash.Changeset.add_error(changeset,
              field: :sprite_id,
              message: "Sandbox not found at provider — will be cleaned up on next access"
            )

          {:error, {:api_error, 400, %{"message" => "Sandbox is not started"}}} ->
            Logger.info("Sandbox #{sprite_id} already stopped, treating as suspended")
            emit_telemetry(start_time, sandbox.id, sprite_id)
            Ash.Changeset.force_change_attribute(changeset, :service_port, nil)

          {:error, reason} ->
            Logger.error("Failed to suspend sandbox #{sprite_id}: #{inspect(reason)}")

            Ash.Changeset.add_error(changeset,
              field: :sprite_id,
              message: "Failed to suspend sandbox: #{inspect(reason)}"
            )
        end
      end
    end)
  end

  defp emit_telemetry(start_time, sandbox_id, sprite_id) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:magus, :sandbox, :suspend],
      %{duration: duration},
      %{sandbox_id: sandbox_id, sprite_id: sprite_id}
    )
  end
end
