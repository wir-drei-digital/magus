defmodule Magus.SuperBrain.Workers.ExtractBrainSourceTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractBrainSource

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp on_exit_drop_graph(brain_id) do
    on_exit(fn -> Magus.Graph.drop("brain:#{brain_id}") end)
  end

  defp zero_usage do
    %Usage{
      model_name: "test-model",
      prompt_tokens: 5,
      completion_tokens: 5,
      total_tokens: 10,
      input_cost: Decimal.new("0"),
      output_cost: Decimal.new("0"),
      total_cost: Decimal.new("0")
    }
  end

  defp ok_extract_topic(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Topic","type":"concept","subtype":null,"confidence":0.8}],"edges":[]}),
       usage: zero_usage()
     }}
  end

  describe "perform/1" do
    test "extracts an ingested source into the brain graph" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      source =
        brain_source(
          brain_id: brain.id,
          user_id: user.id,
          content: "An article about Topic and its uses."
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_topic/2)

      assert :ok = perform_job(ExtractBrainSource, %{"resource_id" => source.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_source and resource_id == ^source.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
      assert episode.graph_name == "brain:#{brain.id}"

      {:ok, result} =
        Magus.Graph.query("brain:#{brain.id}", "MATCH (e:Entity {name: 'Topic'}) RETURN e.name")

      assert [["Topic"]] = result.rows
    end

    test "carries the brain source id as an entity property" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      source = brain_source(brain_id: brain.id, user_id: user.id, content: "Topic content")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_topic/2)
      assert :ok = perform_job(ExtractBrainSource, %{"resource_id" => source.id})

      # The pipeline reserves the `source_id` entity property for the Episode
      # id, so the brain Source's id is carried under `brain_source_id`
      # (mirroring ExtractFileChunk's file_id/chunk_id provenance keys).
      {:ok, result} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Topic'}) RETURN e.brain_source_id"
        )

      assert [[sid]] = result.rows
      assert sid == source.id
    end

    test "skips a source that has not been ingested" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      # No content => status stays :pending.
      source = brain_source(brain_id: brain.id, user_id: user.id)

      assert {:error, :source_not_ingested} =
               perform_job(ExtractBrainSource, %{"resource_id" => source.id})

      {:ok, found} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_source and resource_id == ^source.id)
        |> Ash.read_one(authorize?: false)

      assert found == nil
    end
  end

  describe "Source.ingest enqueue hook" do
    test "ingesting a source enqueues ExtractBrainSource" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      # brain_source/1 with content calls the :ingest action, which fires
      # the after_action hook.
      source = brain_source(brain_id: brain.id, user_id: user.id, content: "ingested body")

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainSource,
        args: %{"resource_id" => source.id}
      )
    end
  end
end
