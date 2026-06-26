defmodule Magus.Agents.Tools.Models.ListModelsTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Tools.Models.ListModels

  setup do
    user = generate(user())
    %{user: user, context: %{user_id: user.id}}
  end

  describe "run/2" do
    test "returns models with full metadata", %{context: context} do
      {:ok, result} = ListModels.run(%{}, context)

      assert is_list(result.models)

      for model <- result.models do
        assert is_binary(model.key)
        assert is_binary(model.name)
        assert is_binary(model.provider)
        assert is_map(model.capabilities)
        assert is_boolean(model.capabilities.supports_tools)
        assert is_boolean(model.capabilities.supports_search)
        assert is_boolean(model.capabilities.supports_reasoning)
        assert is_list(model.input_modalities)
        assert is_list(model.output_modalities)
      end
    end

    test "filters by supports_tools", %{context: context} do
      {:ok, result} = ListModels.run(%{"supports_tools" => true}, context)

      for model <- result.models do
        assert model.capabilities.supports_tools == true
      end
    end

    test "filters by supports_search", %{context: context} do
      {:ok, result} = ListModels.run(%{"supports_search" => true}, context)

      for model <- result.models do
        assert model.capabilities.supports_search == true
      end
    end

    test "filters by supports_reasoning", %{context: context} do
      {:ok, result} = ListModels.run(%{"supports_reasoning" => true}, context)

      for model <- result.models do
        assert model.capabilities.supports_reasoning == true
      end
    end

    test "filters by output_modality", %{context: context} do
      {:ok, result} = ListModels.run(%{"output_modality" => "text"}, context)

      for model <- result.models do
        assert "text" in model.output_modalities
      end
    end

    test "works without context (model listing is not user-scoped)" do
      {:ok, result} = ListModels.run(%{}, %{})
      assert is_list(result.models)
    end
  end

  describe "council mode" do
    test "returns at most one model per provider", %{context: context} do
      {:ok, result} = ListModels.run(%{"mode" => "council"}, context)

      providers = Enum.map(result.models, & &1.provider)
      assert providers == Enum.uniq(providers)
    end

    test "only includes whitelisted providers", %{context: context} do
      {:ok, result} = ListModels.run(%{"mode" => "council"}, context)

      allowed =
        MapSet.new(["Anthropic", "Google", "Swiss AI", "OpenAI", "xAI", "Mistral AI"])

      for model <- result.models do
        assert MapSet.member?(allowed, model.provider),
               "Unexpected provider: #{model.provider}"
      end
    end

    test "all council models support tools", %{context: context} do
      {:ok, result} = ListModels.run(%{"mode" => "council"}, context)

      for model <- result.models do
        assert model.capabilities.supports_tools == true
      end
    end

    test "all council models output text", %{context: context} do
      {:ok, result} = ListModels.run(%{"mode" => "council"}, context)

      for model <- result.models do
        assert "text" in model.output_modalities
      end
    end

    test "treats unknown mode as all (default)", %{context: context} do
      {:ok, all_result} = ListModels.run(%{}, context)
      {:ok, bogus_result} = ListModels.run(%{"mode" => "bogus"}, context)

      assert length(all_result.models) == length(bogus_result.models)
    end
  end

  describe "display_name/0" do
    test "returns display name" do
      assert ListModels.display_name() == "Listing available models..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes model list" do
      assert ListModels.summarize_output(%{models: [%{}, %{}, %{}]}) == "Found 3 models"
    end

    test "summarizes error" do
      assert ListModels.summarize_output(%{error: "oops"}) == "Error: oops"
    end
  end
end
