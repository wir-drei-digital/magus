defmodule Magus.SuperBrain.Workers.NightlyBuildSuperScheduler do
  @moduledoc """
  Enumerates accessors and enqueues one BuildSuperFull per accessor. Runs
  nightly at 03:30 UTC via Oban cron.

  Accessor enumeration:
    * Every user with at least one extracted Episode gets a personal super
      graph build (`super:user:<uid>`).
    * Every active workspace member gets a workspace super graph build
      (`super:workspace:<ws>:<uid>`).

  BuildSuperFull's per-accessor advisory lock prevents duplicate runs even
  if the same accessor is enqueued multiple times (e.g., the scheduler runs
  twice or an incremental enqueue races with the nightly).
  """

  use Oban.Worker, queue: :super_brain_extraction, max_attempts: 1

  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    if Magus.SuperBrain.enabled?(),
      do: do_perform(job),
      else: {:cancel, :super_brain_disabled}
  end

  defp do_perform(%Oban.Job{}) do
    enqueue_personal_super_graphs()
    enqueue_workspace_super_graphs()
    :ok
  end

  defp enqueue_personal_super_graphs do
    user_ids =
      Magus.SuperBrain.Episode
      |> Ash.Query.filter(status == :extracted)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.source_user_id)
      |> Enum.uniq()

    Enum.each(user_ids, fn user_id ->
      _ =
        BuildSuperFull.new(%{
          "accessor_type" => "user",
          "user_id" => user_id,
          "workspace_id" => nil
        })
        |> Oban.insert()
    end)

    Logger.info(
      "NightlyBuildSuperScheduler enqueued #{length(user_ids)} personal super graph builds"
    )
  end

  defp enqueue_workspace_super_graphs do
    members =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Query.filter(is_active == true)
      |> Ash.read!(authorize?: false)

    Enum.each(members, fn m ->
      _ =
        BuildSuperFull.new(%{
          "accessor_type" => "workspace",
          "user_id" => m.user_id,
          "workspace_id" => m.workspace_id
        })
        |> Oban.insert()
    end)

    Logger.info(
      "NightlyBuildSuperScheduler enqueued #{length(members)} workspace super graph builds"
    )
  end
end
