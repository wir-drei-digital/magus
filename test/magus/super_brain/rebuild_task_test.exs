defmodule Mix.Tasks.SuperBrain.RebuildTest do
  @moduledoc """
  Verifies `mix super_brain.rebuild --graph brain:<id>` re-dispatches the
  new Layer-1 episode types: `:brain_source` (by resource_id, like the
  other Extract* workers) and `:brain_pin` (by the page triple stored in
  `Episode.metadata`, since its worker can't be replayed by resource_id).
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  require Ash.Query

  alias Magus.SuperBrain.Episode

  defp extracted_episode(attrs) do
    user_id = Map.fetch!(attrs, :source_user_id)

    {:ok, episode} =
      Episode
      |> Ash.Changeset.for_create(:create, attrs, actor: %{id: user_id})
      |> Ash.create(actor: %{id: user_id})

    {:ok, episode} = Ash.update(episode, %{}, action: :mark_extracted, actor: %{id: user_id})
    episode
  end

  describe "rebuild --graph brain:<id>" do
    test "replays a :brain_source episode via ExtractBrainSource" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      source_id = Ash.UUID.generate()

      extracted_episode(%{
        resource_type: :brain_source,
        resource_id: source_id,
        graph_name: graph,
        raw_text: "ingested source content",
        source_user_id: user.id,
        source_weight: 0.85,
        extractor_version: "brain_source_extract_worker@2026-06-01"
      })

      Mix.Tasks.SuperBrain.Rebuild.run(["--graph", graph, "--yes"])

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainSource,
        args: %{"resource_id" => source_id}
      )
    end

    test "replays a :brain_links episode via IngestBrainLinks by resource_id" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      page_id = Ash.UUID.generate()

      extracted_episode(%{
        resource_type: :brain_links,
        resource_id: page_id,
        graph_name: graph,
        raw_text: "#{Ash.UUID.generate()},#{Ash.UUID.generate()}",
        source_user_id: user.id,
        source_weight: 1.0,
        extractor_version: "brain_links_ingest@2026-06-02",
        metadata: %{
          "source_page_id" => page_id,
          "target_titles" => ["Beta", "Gamma"]
        }
      })

      Mix.Tasks.SuperBrain.Rebuild.run(["--graph", graph, "--yes"])

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.IngestBrainLinks,
        args: %{"resource_id" => page_id}
      )
    end

    test "replays a :brain_pin episode via IngestBrainPin from metadata" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      source_page_id = Ash.UUID.generate()
      target_page_id = Ash.UUID.generate()

      extracted_episode(%{
        resource_type: :brain_pin,
        resource_id: Ash.UUID.generate(),
        graph_name: graph,
        raw_text: "Alpha -[supports]-> Beta",
        source_user_id: user.id,
        source_weight: 1.5,
        extractor_version: "brain_pin_ingest@2026-06-01",
        metadata: %{
          "source_page_id" => source_page_id,
          "target_page_id" => target_page_id,
          "predicate" => "supports"
        }
      })

      Mix.Tasks.SuperBrain.Rebuild.run(["--graph", graph, "--yes"])

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.IngestBrainPin,
        args: %{
          "source_page_id" => source_page_id,
          "target_page_id" => target_page_id,
          "predicate" => "supports",
          "user_id" => user.id
        }
      )
    end

    test "skips a :brain_pin episode with no replay metadata (predates support)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      graph = "brain:#{brain.id}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      extracted_episode(%{
        resource_type: :brain_pin,
        resource_id: Ash.UUID.generate(),
        graph_name: graph,
        raw_text: "legacy pin",
        source_user_id: user.id,
        source_weight: 1.5,
        extractor_version: "brain_pin_ingest@legacy"
      })

      Mix.Tasks.SuperBrain.Rebuild.run(["--graph", graph, "--yes"])

      refute_enqueued(worker: Magus.SuperBrain.Workers.IngestBrainPin)
    end
  end
end
