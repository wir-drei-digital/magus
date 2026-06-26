defmodule Magus.SuperBrain.Workers.ExtractFileChunkTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractFileChunk

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

  defp ok_extract_graphrag(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"GraphRAG","type":"concept","subtype":null,"confidence":0.8}],"edges":[]}),
       usage: zero_usage()
     }}
  end

  describe "perform/1" do
    test "extracts from a text file's chunk into the user files graph" do
      user = generate(user())
      file = generate(file(user_id: user.id, type: :text))

      chunk =
        generate(chunk(file_id: file.id, content: "GraphRAG is a hybrid retrieval pattern"))

      graph = "files:user:#{user.id}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_graphrag/2)

      assert :ok = perform_job(ExtractFileChunk, %{"resource_id" => chunk.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :file_chunk and resource_id == ^chunk.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
      assert episode.graph_name == graph
      assert episode.extractor_version == "file_chunk_extract_worker@2026-05-21"

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (e:Entity {name: 'GraphRAG'}) RETURN e.name")

      assert [["GraphRAG"]] = result.rows
    end

    test "extracts from a workspace document chunk into the workspace files graph" do
      user = generate(user())
      ws = generate(workspace(actor: user))

      file =
        generate(file(user_id: user.id, workspace_id: ws.id, type: :document))

      chunk = generate(chunk(file_id: file.id, content: "Workspace doc content"))

      graph = "files:workspace:#{ws.id}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_graphrag/2)
      assert :ok = perform_job(ExtractFileChunk, %{"resource_id" => chunk.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :file_chunk and resource_id == ^chunk.id)
        |> Ash.read_one(authorize?: false)

      assert episode.graph_name == graph
      assert episode.status == :extracted
    end

    test "skips when parent file type is :image" do
      user = generate(user())
      file = generate(file(user_id: user.id, type: :image))
      chunk = generate(chunk(file_id: file.id, content: "caption"))

      assert {:error, :file_type_not_extractable} =
               perform_job(ExtractFileChunk, %{"resource_id" => chunk.id})

      {:ok, found} =
        Episode
        |> Ash.Query.filter(resource_type == :file_chunk and resource_id == ^chunk.id)
        |> Ash.read_one(authorize?: false)

      assert found == nil
    end

    test "carries file_id and chunk_id as entity properties" do
      user = generate(user())
      file = generate(file(user_id: user.id, type: :text))
      chunk = generate(chunk(file_id: file.id, content: "Some text"))
      graph = "files:user:#{user.id}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_graphrag/2)
      :ok = perform_job(ExtractFileChunk, %{"resource_id" => chunk.id})

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'GraphRAG'}) RETURN e.file_id, e.chunk_id"
        )

      assert [[file_id, chunk_id]] = result.rows
      # FalkorDB string-decodes scalar properties, so compare as strings or as-is.
      assert file_id == file.id or file_id == to_string(file.id)
      assert chunk_id == chunk.id or chunk_id == to_string(chunk.id)
    end
  end
end
