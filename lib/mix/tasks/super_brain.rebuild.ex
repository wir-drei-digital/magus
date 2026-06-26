defmodule Mix.Tasks.SuperBrain.Rebuild do
  @shortdoc "Rebuild a FalkorDB graph from Postgres episodes."

  @moduledoc """
  Replays all extracted episodes for a given graph back into FalkorDB.
  Useful for disaster recovery, testing, and version migration.

      mix super_brain.rebuild --graph brain:<brain_id>           # brain page graph
      mix super_brain.rebuild --graph memories:user:<user_id>    # personal memory graph
      mix super_brain.rebuild --graph memories:workspace:<ws_id> # workspace memory graph
      mix super_brain.rebuild --graph files:user:<user_id>       # personal files graph
      mix super_brain.rebuild --graph files:workspace:<ws_id>    # workspace files graph
      mix super_brain.rebuild --graph drafts:user:<user_id>      # drafts graph

      mix super_brain.rebuild --graph super:user:<uid> --yes              # personal super graph
      mix super_brain.rebuild --graph super:workspace:<ws>:<uid> --yes    # workspace super graph

      mix super_brain.rebuild --graph <graph> --yes              # no confirmation prompt

  Replays serially with progress logging. Drops the existing graph first.
  Dispatches to the correct worker (ExtractBrainPage / ExtractBrainSource /
  ExtractMemory / ExtractFileChunk / ExtractDraft / IngestBrainLinks) based on
  each Episode's resource_type. `:brain_links` episodes replay by resource_id
  (= page id); `IngestBrainLinks` re-reads `brain_page_links`. `:brain_pin`
  episodes are re-dispatched to `IngestBrainPin` from the page triple stored
  in `Episode.metadata`.

  For `super:` prefixed graphs, the rebuild drops the FalkorDB graph and
  enqueues `BuildSuperFull` for the corresponding accessor instead of
  replaying episodes (Layer 2 super graphs are derived from Layer 1, not
  from Postgres episodes).
  """

  use Mix.Task

  alias Magus.SuperBrain.Episode

  require Ash.Query

  @workers %{
    brain_page: Magus.SuperBrain.Workers.ExtractBrainPage,
    brain_source: Magus.SuperBrain.Workers.ExtractBrainSource,
    brain_links: Magus.SuperBrain.Workers.IngestBrainLinks,
    memory: Magus.SuperBrain.Workers.ExtractMemory,
    file_chunk: Magus.SuperBrain.Workers.ExtractFileChunk,
    draft: Magus.SuperBrain.Workers.ExtractDraft
  }

  defp worker_for(resource_type), do: Map.get(@workers, resource_type)

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [graph: :string, yes: :boolean])
    graph = Keyword.fetch!(opts, :graph)

    unless Keyword.get(opts, :yes, false) do
      Mix.shell().info(
        "About to DROP graph #{graph} and re-enqueue all extracted episodes for it."
      )

      case Mix.shell().yes?("This deletes all FalkorDB data for #{graph}. Continue?") do
        true -> :ok
        false -> Mix.raise("Aborted by user. Pass --yes to skip this prompt.")
      end
    end

    Mix.Task.run("app.start")

    if String.starts_with?(graph, "super:") do
      rebuild_super_graph(graph)
    else
      rebuild_layer1_graph(graph)
    end
  end

  defp rebuild_layer1_graph(graph) do
    Mix.shell().info("Dropping #{graph}...")
    Magus.Graph.drop(graph)

    episodes =
      Episode
      |> Ash.Query.filter(graph_name == ^graph and status == :extracted)
      |> Ash.read!(authorize?: false)

    Mix.shell().info("Replaying #{length(episodes)} episodes...")

    Enum.each(episodes, &enqueue_replay/1)

    Mix.shell().info("Done. Watch Oban for completion.")
  end

  # `:brain_pin` episodes can't be replayed by `resource_id` (the worker
  # takes the page triple, and `resource_id` is a one-way hash). They carry
  # the triple in `metadata`; rebuild re-dispatches `IngestBrainPin` from it.
  # Pin episodes written before metadata support are skipped with a notice.
  defp enqueue_replay(%Episode{resource_type: :brain_pin} = episode) do
    case pin_args(episode) do
      {:ok, args} ->
        args
        |> Magus.SuperBrain.Workers.IngestBrainPin.new()
        |> Oban.insert!()

      :error ->
        Mix.shell().info(
          "  skipping pin #{episode.id}: no replay metadata (predates metadata support)"
        )
    end
  end

  defp enqueue_replay(%Episode{} = episode) do
    case worker_for(episode.resource_type) do
      nil ->
        Mix.shell().info(
          "  skipping #{episode.id}: no worker for resource_type=#{inspect(episode.resource_type)}"
        )

      worker_module when is_atom(worker_module) ->
        %{"resource_id" => episode.resource_id}
        |> worker_module.new()
        |> Oban.insert!()
    end
  end

  defp pin_args(%Episode{metadata: meta, source_user_id: uid}) when is_map(meta) do
    with %{
           "source_page_id" => sid,
           "target_page_id" => tid,
           "predicate" => pred
         } <- meta,
         true <- is_binary(sid) and is_binary(tid) and is_binary(pred) do
      {:ok,
       %{
         "source_page_id" => sid,
         "target_page_id" => tid,
         "predicate" => pred,
         "user_id" => uid
       }}
    else
      _ -> :error
    end
  end

  defp pin_args(_), do: :error

  defp rebuild_super_graph(graph) do
    Mix.shell().info("Dropping #{graph}...")
    Magus.Graph.drop(graph)

    case parse_super_graph_name(graph) do
      {:ok, accessor} ->
        args = %{
          "accessor_type" => Atom.to_string(accessor.type),
          "user_id" => accessor.user_id,
          "workspace_id" => accessor.workspace_id
        }

        Magus.SuperBrain.Workers.BuildSuperFull.new(args)
        |> Oban.insert!()

        Mix.shell().info("Enqueued BuildSuperFull for #{graph}")

      {:error, reason} ->
        Mix.shell().error("Could not parse super graph name #{graph}: #{inspect(reason)}")
    end
  end

  defp parse_super_graph_name("super:user:" <> uid) do
    {:ok, %{type: :user, user_id: uid, workspace_id: nil}}
  end

  defp parse_super_graph_name("super:workspace:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [ws_id, uid] -> {:ok, %{type: :workspace, user_id: uid, workspace_id: ws_id}}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_super_graph_name(_), do: {:error, :unknown_prefix}
end
