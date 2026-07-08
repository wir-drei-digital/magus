defmodule Magus.SuperBrain.Workers.RetractResource do
  @moduledoc """
  Removes a hard-deleted resource's derived Super Brain data.

  Postgres is the definitive cleanup: deleting the Episode rows for the
  resource cascades to Claims (FK on_delete: :delete), which removes the
  facts from claims-backed retrieval. The L1 graph episode node is deleted
  best-effort; orphaned entity nodes and stale L2 edges are accepted and
  healed by the next replay or migration sweep (the graph is a derived,
  disposable index).

  Generic over resource_type so future hard-delete paths (drafts, files)
  can reuse it.
  """

  use Oban.Worker,
    queue: :super_brain_extraction,
    max_attempts: 5,
    unique: [period: 60, fields: [:args]]

  require Ecto.Query
  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"resource_id" => resource_id} = args}) do
    resource_type = Map.get(args, "resource_type", "memory")
    graph_name = Map.get(args, "graph_name")

    delete_episodes(resource_type, resource_id)
    delete_graph_episode(graph_name, resource_id)

    :ok
  end

  defp delete_episodes(resource_type, resource_id) do
    {count, _} =
      Magus.SuperBrain.Episode
      |> Ecto.Query.from()
      |> Ecto.Query.where(
        [e],
        e.resource_type == ^resource_type and e.resource_id == ^resource_id
      )
      |> Magus.Repo.delete_all()

    Logger.debug(
      "RetractResource: deleted #{count} episode rows for #{resource_type}/#{resource_id}"
    )
  end

  defp delete_graph_episode(nil, _resource_id), do: :ok

  defp delete_graph_episode(graph_name, resource_id) do
    case Magus.Graph.query(
           graph_name,
           "MATCH (e:Episode {resource_id: $resource_id}) DETACH DELETE e",
           %{resource_id: to_string(resource_id)}
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RetractResource: graph episode delete failed for #{graph_name}: #{inspect(reason)} - stale graph data heals on rebuild"
        )

        :ok
    end
  end
end
