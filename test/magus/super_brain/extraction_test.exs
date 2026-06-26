defmodule Magus.SuperBrain.ExtractionTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.SuperBrain.Extraction

  setup :verify_on_exit!

  defp build_usage(opts \\ []) do
    %Magus.SuperBrain.Usage{
      model_name: Keyword.get(opts, :model_name, "test-model"),
      provider: Keyword.get(opts, :provider, "openrouter"),
      prompt_tokens: Keyword.get(opts, :prompt_tokens, 100),
      completion_tokens: Keyword.get(opts, :completion_tokens, 50),
      total_tokens: Keyword.get(opts, :total_tokens, 150),
      cached_tokens: Keyword.get(opts, :cached_tokens, 0),
      input_cost: Keyword.get(opts, :input_cost, Decimal.new("0.001")),
      output_cost: Keyword.get(opts, :output_cost, Decimal.new("0.002")),
      total_cost: Keyword.get(opts, :total_cost, Decimal.new("0.003"))
    }
  end

  describe "extract/2" do
    test "returns parsed entities, edges, usage, and user_id on success" do
      raw_json = """
      {
        "entities": [
          {"name": "Daniel", "type": "person", "subtype": null, "confidence": 0.9},
          {"name": "Project X", "type": "project", "subtype": "internal", "confidence": 0.8}
        ],
        "edges": [
          {"subject_name": "Daniel", "object_name": "Project X", "predicate": "works_on", "confidence": 0.85}
        ]
      }
      """

      expect(Magus.SuperBrain.LLMMock, :complete, fn _messages, _opts ->
        {:ok, %{content: raw_json, usage: build_usage()}}
      end)

      assert {:ok,
              %{
                entities: entities,
                edges: edges,
                usage: %Magus.SuperBrain.Usage{total_tokens: 150},
                user_id: "user-123"
              }} =
               Extraction.extract("Daniel works on Project X", user_id: "user-123")

      assert length(entities) == 2
      assert length(edges) == 1
      first = hd(entities)
      assert first.name == "Daniel"
      assert first.type == :person
    end

    test "returns {:error, :invalid_json} when LLM output is not JSON" do
      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok, %{content: "not json", usage: build_usage()}}
      end)

      assert {:error, :invalid_json} = Extraction.extract("anything")
    end

    test "parses JSON wrapped in markdown code fences" do
      fenced = """
      ```json
      {"entities": [{"name": "Daniel", "type": "person", "subtype": null, "confidence": 0.9}], "edges": []}
      ```
      """

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok, %{content: fenced, usage: build_usage()}}
      end)

      assert {:ok, %{entities: entities}} = Extraction.extract("anything")
      assert length(entities) == 1
      assert hd(entities).name == "Daniel"
    end

    test "parses a JSON object surrounded by prose" do
      chatty =
        ~s(Here is the extraction:\n{"entities": [{"name": "Lisa", "type": "person", "subtype": null, "confidence": 0.8}], "edges": []}\nHope this helps!)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok, %{content: chatty, usage: build_usage()}}
      end)

      assert {:ok, %{entities: entities}} = Extraction.extract("anything")
      assert length(entities) == 1
      assert hd(entities).name == "Lisa"
    end

    test "filters edges whose subject/object are not in entities" do
      raw_json = """
      {
        "entities": [{"name": "A", "type": "concept", "subtype": null, "confidence": 0.5}],
        "edges": [
          {"subject_name": "A", "object_name": "GHOST", "predicate": "relates_to", "confidence": 0.7}
        ]
      }
      """

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok, %{content: raw_json, usage: build_usage()}}
      end)

      assert {:ok, %{edges: [], usage: %Magus.SuperBrain.Usage{}, user_id: nil}} =
               Extraction.extract("anything")
    end

    test "skips entities with missing required fields" do
      raw_json = ~s({
        "entities": [
          {"name": "Daniel", "type": "person", "confidence": 0.9},
          {"name": "incomplete"}
        ],
        "edges": []
      })

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content: raw_json,
           usage:
             build_usage(
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 0,
               input_cost: Decimal.new("0"),
               output_cost: Decimal.new("0"),
               total_cost: Decimal.new("0")
             )
         }}
      end)

      assert {:ok, %{entities: entities}} = Extraction.extract("anything")
      assert length(entities) == 1
      assert hd(entities).name == "Daniel"
    end

    test "skips edges with missing required fields" do
      raw_json = ~s({
        "entities": [{"name": "A", "type": "concept", "confidence": 0.5}],
        "edges": [
          {"subject_name": "A", "object_name": "A", "predicate": "relates_to", "confidence": 0.7},
          {"subject_name": "X"}
        ]
      })

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content: raw_json,
           usage:
             build_usage(
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 0,
               input_cost: Decimal.new("0"),
               output_cost: Decimal.new("0"),
               total_cost: Decimal.new("0")
             )
         }}
      end)

      assert {:ok, %{edges: edges}} = Extraction.extract("anything")
      assert length(edges) == 1
    end
  end
end
