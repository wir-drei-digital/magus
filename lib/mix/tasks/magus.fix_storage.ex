defmodule Mix.Tasks.Magus.FixStorage do
  @moduledoc """
  Recalculate storage usage for a user to fix drift.

  Storage drift can occur if the server crashes after a file is deleted
  but before the counter is decremented. This task recalculates the
  actual storage usage by summing all file sizes.

  ## Usage

      mix magus.fix_storage <user_id>

  ## Examples

      mix magus.fix_storage 123e4567-e89b-12d3-a456-426614174000

  """

  use Mix.Task

  @shortdoc "Recalculate storage usage for a user"

  @impl Mix.Task
  def run([user_id]) do
    Mix.Task.run("app.start")

    case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
      {:ok, subscription} ->
        old_usage = subscription.storage_usage_bytes

        case Magus.Usage.recalculate_storage(subscription, authorize?: false) do
          {:ok, updated} ->
            new_usage = updated.storage_usage_bytes

            Mix.shell().info("""
            Storage recalculated for user #{user_id}
              Old value: #{format_bytes(old_usage)}
              New value: #{format_bytes(new_usage)}
              Difference: #{format_bytes(new_usage - old_usage)}
            """)

          {:error, error} ->
            Mix.shell().error("Failed to recalculate storage: #{inspect(error)}")
            exit({:shutdown, 1})
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        Mix.shell().error("No subscription found for user #{user_id}")
        exit({:shutdown, 1})

      {:error, error} ->
        Mix.shell().error("Failed to get subscription: #{inspect(error)}")
        exit({:shutdown, 1})
    end
  end

  def run(_) do
    Mix.shell().info("""
    Usage: mix magus.fix_storage <user_id>

    Recalculates storage usage for a user by summing actual file sizes.
    Use this to fix storage drift after server crashes.
    """)
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 2)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} bytes"
end
