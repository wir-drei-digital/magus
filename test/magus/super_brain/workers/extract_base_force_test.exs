defmodule Magus.SuperBrain.Workers.ExtractBaseForceTest do
  @moduledoc """
  Task 10: the `"force" => true` job arg bypasses BOTH fingerprint gates
  (the pre-LLM-call gate and the in-transaction re-check gate) so unchanged
  content re-extracts once instead of short-circuiting via `:skip_unchanged`.

  Reuses `ExtractBaseTest`'s minimal `TestWorker` pattern rather than a real
  per-resource worker, since the force gate is a pipeline-level concern
  (`gate_extract_persist/4` / `persist_extraction/6`) that every worker goes
  through identically.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage

  setup :set_mox_from_context
  setup :verify_on_exit!

  defmodule TestWorker do
    @moduledoc false
    use Magus.SuperBrain.Workers.ExtractBase, queue: :super_brain_extraction

    @extractor_version "test_force_worker@1.0"

    @impl true
    def extractor_version, do: @extractor_version

    @impl true
    def load(%{"user_id" => uid, "text" => text, "graph" => graph} = args) do
      {:ok,
       %{
         user_id: uid,
         raw_text: text,
         graph_name: graph,
         resource_type: :brain_page,
         resource_id: Map.get(args, "resource_id", Ash.UUID.generate()),
         source_weight: 1.0,
         extra_node_props: %{}
       }}
    end

    def load(_), do: {:error, :unknown_args}
  end

  defp on_exit_drop_graph(graph) do
    on_exit(fn -> Magus.Graph.drop(graph) end)
  end

  defp ok_one_entity(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"T","type":"concept","subtype":null,"confidence":0.8}],"claims":[]}),
       usage: %Usage{
         model_name: "test-model",
         total_tokens: 10,
         prompt_tokens: 5,
         completion_tokens: 5,
         input_cost: Decimal.new("0"),
         output_cost: Decimal.new("0"),
         total_cost: Decimal.new("0")
       }
     }}
  end

  defp current_episode(resource_id) do
    Episode
    |> Ash.Query.filter(
      resource_type == :brain_page and resource_id == ^resource_id and status == :extracted
    )
    |> Ash.read_one!(authorize?: false)
  end

  describe "force gate" do
    test "without force, re-running with unchanged content skips (no fresh episode)" do
      user = generate(user())
      graph = "test:base:force:no_force:#{user.id}:#{System.unique_integer([:positive])}"
      resource_id = Ash.UUID.generate()
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      first_episode = current_episode(resource_id)
      assert first_episode.status == :extracted

      # No LLMMock expectation set: the fingerprint gate should short-circuit
      # BEFORE any LLM call, so an unexpected call here would raise via Mox.
      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      second_episode = current_episode(resource_id)
      assert second_episode.id == first_episode.id
    end

    test "with force, re-running with unchanged content re-extracts (fresh episode, prior superseded)" do
      user = generate(user())
      graph = "test:base:force:with_force:#{user.id}:#{System.unique_integer([:positive])}"
      resource_id = Ash.UUID.generate()
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph,
                 "resource_id" => resource_id
               })

      first_episode = current_episode(resource_id)
      assert first_episode.status == :extracted

      # Same content bytes as the first run, plus "force" => true. The LLM
      # mock expectation below is REQUIRED: if force did not bypass the
      # gate, `gate_on_fingerprint` would return `:skip_unchanged` before
      # ever calling the LLM and this expectation would go unmet (Mox raises
      # at `verify_on_exit!`).
      expect(Magus.SuperBrain.LLMMock, :complete, &ok_one_entity/2)

      assert :ok =
               perform_job(TestWorker, %{
                 "user_id" => user.id,
                 "text" => "hello",
                 "graph" => graph,
                 "resource_id" => resource_id,
                 "force" => true
               })

      second_episode = current_episode(resource_id)
      assert second_episode.id != first_episode.id
      assert second_episode.status == :extracted

      {:ok, reloaded_first} = Ash.get(Episode, first_episode.id, authorize?: false)
      assert reloaded_first.status == :superseded
    end
  end
end
