defmodule Magus.Sandbox.Sandbox.Changes.Terminate do
  @moduledoc """
  Terminates a sandbox by destroying its backing resource.

  This change:
  1. Destroys the sandbox if it exists
  2. Clears sprite_id, sprite_url, checkpoint_id, and service_port
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Sandbox.Provider

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      sandbox = changeset.data
      sprite_id = sandbox.sprite_id
      start_time = System.monotonic_time()

      # Only try to destroy if we have a sprite_id
      result =
        if sprite_id do
          client = Provider.client_for(sandbox)

          case apply(client, :destroy, [sprite_id]) do
            :ok ->
              {:ok, clear_sprite_attrs(changeset)}

            {:error, :not_found} ->
              # Already gone, just clear attributes
              Logger.warning(
                "Sandbox #{sprite_id} not found during termination, clearing attributes"
              )

              {:ok, clear_sprite_attrs(changeset)}

            {:error, reason} ->
              Logger.error("Failed to destroy sandbox #{sprite_id}: #{inspect(reason)}")
              {:error, reason}
          end
        else
          # No sprite to destroy, just clear any leftover attributes
          {:ok, clear_sprite_attrs(changeset)}
        end

      case result do
        {:ok, updated_changeset} ->
          duration = System.monotonic_time() - start_time

          :telemetry.execute(
            [:magus, :sandbox, :terminate],
            %{duration: duration},
            %{sandbox_id: sandbox.id, sprite_id: sprite_id}
          )

          updated_changeset

        {:error, reason} ->
          Ash.Changeset.add_error(changeset, "Failed to terminate sandbox: #{inspect(reason)}")
      end
    end)
  end

  defp clear_sprite_attrs(changeset) do
    changeset
    |> Ash.Changeset.force_change_attribute(:sprite_id, nil)
    |> Ash.Changeset.force_change_attribute(:sprite_url, nil)
    |> Ash.Changeset.force_change_attribute(:checkpoint_id, nil)
    |> Ash.Changeset.force_change_attribute(:service_port, nil)
  end
end
