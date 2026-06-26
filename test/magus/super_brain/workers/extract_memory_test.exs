defmodule Magus.SuperBrain.Workers.ExtractMemoryTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractMemory

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp on_exit_drop_graph(graph) do
    on_exit(fn -> Magus.Graph.drop(graph) end)
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

  defp ok_extract_berlin(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"Berlin","type":"location","subtype":null,"confidence":0.8}],"edges":[]}),
       usage: zero_usage()
     }}
  end

  describe "perform/1" do
    test "extracts entities from a :user memory into the user memories graph" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(user_id: user.id, scope: :user, summary: "User is based in Berlin")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_berlin/2)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
      assert episode.graph_name == graph
      assert episode.extractor_version == "memory_extract_worker@2026-05-21"

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'Berlin'}) RETURN e.name"
        )

      assert [["Berlin"]] = result.rows
    end

    test "skips re-extraction when summary fingerprint unchanged" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory = memory(user_id: user.id, scope: :user, summary: "same")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_berlin/2)
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})
      verify!(Magus.SuperBrain.LLMMock)

      # Second run with same content: must NOT call the LLM. Mox is in
      # global mode so any unexpected call would raise.
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})
    end

    test "agent-scoped memories land in the owning user's memory graph" do
      user = generate(user())
      agent = custom_agent(user)
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(
          user_id: user.id,
          scope: :agent,
          custom_agent_id: agent.id,
          summary: "Agent prefers concise replies"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_berlin/2)
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert episode.graph_name == graph
      assert episode.status == :extracted

      # The extracted node should carry the custom_agent_id property so callers
      # can filter agent-scoped memories out of the same graph.
      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'Berlin'}) RETURN e.custom_agent_id"
        )

      assert [[agent_id_on_node]] = result.rows
      assert agent_id_on_node == agent.id
    end

    test "memories with kind :fact route through :memory_explicit and reach :instruction tier" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      # Create directly so we can set kind: :fact (the generator doesn't
      # expose `kind` as an opt).
      {:ok, memory} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Lives in Berlin",
          %{
            summary: "User lives in Berlin",
            content: %{"text" => "User lives in Berlin"},
            kind: :fact
          },
          authorize?: false
        )

      # High-confidence entity so it CAN reach :instruction tier.
      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Berlin","type":"location","subtype":null,"confidence":0.95}],"edges":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Berlin'}) RETURN e.trust_tier")

      assert [["instruction"]] = result.rows
    end

    test "memories with kind :preference also reach :instruction tier" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      {:ok, memory} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Coffee preference",
          %{
            summary: "User prefers coffee black",
            content: %{"text" => "User prefers coffee black"},
            kind: :preference
          },
          authorize?: false
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_berlin/2)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Berlin'}) RETURN e.trust_tier")

      # `ok_extract_berlin/2` returns confidence 0.8 which is BELOW the 0.9
      # instruction threshold, so the entity stays at :evidence even when
      # the source is :memory_explicit. This is the intended behaviour:
      # source elevation only takes effect at high confidence.
      assert [["evidence"]] = result.rows
    end

    test "memories with non-explicit kinds stay at :llm_extract (:evidence tier)" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      {:ok, memory} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Hypothesis about Berlin",
          %{
            summary: "Maybe user lives in Berlin",
            content: %{"text" => "Maybe user lives in Berlin"},
            kind: :hypothesis
          },
          authorize?: false
        )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"Berlin","type":"location","subtype":null,"confidence":0.95}],"edges":[]}),
           usage: zero_usage()
         }}
      end)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'Berlin'}) RETURN e.trust_tier")

      # :hypothesis is not in @explicit_memory_kinds, so source is
      # :llm_extract and the entity stays at :evidence even with 0.95
      # confidence.
      assert [["evidence"]] = result.rows
    end

    test "workspace :user memory routes to workspace memories graph" do
      user = generate(user())
      ws = generate(workspace(actor: user))
      graph = "memories:workspace:#{ws.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(
          user_id: user.id,
          workspace_id: ws.id,
          scope: :user,
          summary: "workspace-scoped memory about Berlin"
        )

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_berlin/2)
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert episode.graph_name == graph
      assert episode.status == :extracted
    end
  end
end
