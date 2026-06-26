defmodule Magus.SuperBrain.Workers.IngestBrainPinTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Workers.IngestBrainPin

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp on_exit_drop_graph(brain_id) do
    on_exit(fn -> Magus.Graph.drop("brain:#{brain_id}") end)
  end

  defp args(source, target, predicate, user) do
    %{
      "source_page_id" => source.id,
      "target_page_id" => target.id,
      "predicate" => predicate,
      "user_id" => user.id
    }
  end

  describe "perform/1" do
    test "writes an instruction-tier edge and an extracted Episode" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      a = brain_page(brain_id: brain.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      assert :ok = perform_job(IngestBrainPin, args(a, b, "supports", user))

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_pin and status == :extracted)
        |> Ash.read_one(authorize?: false)

      assert episode.graph_name == "brain:#{brain.id}"

      {:ok, edge} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (s:Entity {name: 'Alpha'})-[r:RELATES_TO]->(t:Entity {name: 'Beta'}) RETURN r.trust_tier, r.predicate"
        )

      assert [["instruction", "supports"]] = edge.rows

      {:ok, ext} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Alpha'}) RETURN e.extractor"
        )

      assert [[extractor]] = ext.rows
      assert String.starts_with?(extractor, "brain_pin_ingest")

      # The pin persists its replay triple so super_brain.rebuild can
      # re-dispatch it (resource_id is a one-way hash).
      assert episode.metadata["source_page_id"] == a.id
      assert episode.metadata["target_page_id"] == b.id
      assert episode.metadata["predicate"] == "supports"

      # Every Entity node carries normalized_subtype (nil for pins) so the
      # canonicalize / cluster passes can rely on the property existing.
      {:ok, subtype} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Alpha'}) RETURN e.normalized_subtype"
        )

      assert [[nil]] = subtype.rows
    end

    test "re-pinning the same pair supersedes the prior pin episode" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      a = brain_page(brain_id: brain.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      assert :ok = perform_job(IngestBrainPin, args(a, b, "supports", user))
      assert :ok = perform_job(IngestBrainPin, args(a, b, "supports", user))

      {:ok, extracted} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_pin and status == :extracted)
        |> Ash.read(authorize?: false)

      assert length(extracted) == 1

      {:ok, all} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_pin)
        |> Ash.read(authorize?: false)

      assert length(all) == 2
      assert Enum.sort(Enum.map(all, & &1.status)) == [:extracted, :superseded]
    end

    test "fans out BuildSuperIncremental for the brain's accessors" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      a = brain_page(brain_id: brain.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      assert :ok = perform_job(IngestBrainPin, args(a, b, "supports", user))

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.BuildSuperIncremental,
        args: %{"user_id" => user.id, "accessor_type" => "user", "workspace_id" => nil}
      )
    end

    test "rejects pages that live in different brains" do
      user = generate(user())
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))

      a = brain_page(brain_id: brain_a.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain_b.id, user_id: user.id, title: "Beta", content: "b")

      assert {:error, :pages_in_different_brains} =
               perform_job(IngestBrainPin, args(a, b, "supports", user))
    end

    test "rejects a job with missing args" do
      assert {:error, :missing_pin_args} = perform_job(IngestBrainPin, %{})
    end
  end
end
