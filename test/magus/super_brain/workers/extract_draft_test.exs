defmodule Magus.SuperBrain.Workers.ExtractDraftTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractDraft

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

  defp ok_extract_draft_idea(_messages, _opts) do
    {:ok,
     %{
       content:
         ~s({"entities":[{"name":"DraftIdea","type":"concept","subtype":null,"confidence":0.8}],"claims":[]}),
       usage: zero_usage()
     }}
  end

  describe "perform/1" do
    test "extracts a draft into the user drafts graph" do
      user = generate(user())
      draft = draft(user_id: user.id, content: "DraftIdea is a scratchpad concept")
      graph = "drafts:user:#{user.id}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_draft_idea/2)

      assert :ok = perform_job(ExtractDraft, %{"resource_id" => draft.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :draft and resource_id == ^draft.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted
      assert episode.graph_name == graph
      assert episode.extractor_version == "draft_extract_worker@2026-07-04-claims"

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (e:Entity {name: 'DraftIdea'}) RETURN e.name, e.conversation_id"
        )

      assert [["DraftIdea", conv_id_on_node]] = result.rows

      assert conv_id_on_node == draft.conversation_id or
               conv_id_on_node == to_string(draft.conversation_id)
    end

    test "skips re-extraction when content fingerprint unchanged" do
      user = generate(user())
      draft = draft(user_id: user.id, content: "stable scratchpad text")
      graph = "drafts:user:#{user.id}"
      on_exit_drop_graph(graph)

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_draft_idea/2)
      assert :ok = perform_job(ExtractDraft, %{"resource_id" => draft.id})
      verify!(Magus.SuperBrain.LLMMock)

      # Second run with the same content must NOT call the LLM. Mox is in
      # global mode so any unexpected call would raise.
      assert :ok = perform_job(ExtractDraft, %{"resource_id" => draft.id})
    end
  end
end
