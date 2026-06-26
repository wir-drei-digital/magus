defmodule Magus.Sandbox.Sandbox.Changes.Resume do
  @moduledoc """
  Resumes a suspended sandbox.

  Calls the provider's `restore/2` which either restores from a checkpoint
  or simply verifies the sandbox still exists (for providers that auto-wake).
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Sandbox.Provider

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      sandbox = changeset.data
      sprite_id = sandbox.sprite_id

      if is_nil(sprite_id) do
        Ash.Changeset.add_error(changeset,
          field: :sprite_id,
          message: "Cannot resume sandbox without sprite_id"
        )
      else
        client = Provider.client_for(sandbox)
        start_time = System.monotonic_time()

        case apply(client, :restore, [sprite_id, sandbox.checkpoint_id]) do
          {:ok, %{sprite_id: new_sprite_id, url: url}} ->
            emit_telemetry(start_time, sandbox.id, sprite_id)

            changeset
            |> Ash.Changeset.force_change_attribute(:sprite_id, new_sprite_id)
            |> Ash.Changeset.force_change_attribute(:sprite_url, url)
            |> Ash.Changeset.force_change_attribute(:checkpoint_id, nil)

          {:ok, %{sprite_id: new_sprite_id}} ->
            emit_telemetry(start_time, sandbox.id, sprite_id)

            changeset
            |> Ash.Changeset.force_change_attribute(:sprite_id, new_sprite_id)
            |> Ash.Changeset.force_change_attribute(:checkpoint_id, nil)

          {:error, :not_found} ->
            Logger.error("Sandbox not found during resume: #{sprite_id}")

            Ash.Changeset.add_error(changeset,
              field: :sprite_id,
              message: "Sandbox not found. It may have been destroyed."
            )

          {:error, reason} ->
            Logger.error("Failed to resume sandbox #{sprite_id}: #{inspect(reason)}")

            Ash.Changeset.add_error(changeset,
              field: :sprite_id,
              message: "Failed to resume sandbox: #{inspect(reason)}"
            )
        end
      end
    end)
  end

  defp emit_telemetry(start_time, sandbox_id, sprite_id) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:magus, :sandbox, :resume],
      %{duration: duration},
      %{sandbox_id: sandbox_id, sprite_id: sprite_id}
    )
  end
end
