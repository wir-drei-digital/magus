defmodule Magus.Knowledge.SyncRecovery do
  @moduledoc """
  Resets collections stuck in `:syncing` state on application startup.

  When the server restarts, any Oban sync jobs that were executing are lost.
  This module detects collections still marked as `:syncing` and resets them
  to `:error` so they can be re-triggered.
  """

  use Task, restart: :transient

  require Ash.Query
  require Logger

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    stuck =
      Magus.Knowledge.KnowledgeCollection
      |> Ash.Query.filter(sync_status == :syncing)
      |> Ash.read!(authorize?: false)

    if Enum.any?(stuck) do
      Logger.info("SyncRecovery: resetting #{length(stuck)} stuck syncing collection(s)")

      Enum.each(stuck, fn collection ->
        Magus.Knowledge.update_sync_status(
          collection,
          %{sync_status: :error, last_error: "Sync interrupted (server restart)"},
          authorize?: false
        )
      end)
    end
  end
end
