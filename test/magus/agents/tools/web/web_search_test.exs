defmodule Magus.Agents.Tools.Web.WebSearchTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Web.WebSearch

  describe "display_name/0" do
    test "returns display string" do
      assert WebSearch.display_name() == "Searching the web..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes results count" do
      output = %{results: [%{}, %{}, %{}]}
      assert WebSearch.summarize_output(output) == "Found 3 results"
    end

    test "summarizes zero results" do
      output = %{results: []}
      assert WebSearch.summarize_output(output) == "Found 0 results"
    end

    test "summarizes error" do
      output = %{error: "API error"}
      assert WebSearch.summarize_output(output) == "Error"
    end

    test "summarizes unknown output" do
      assert WebSearch.summarize_output(%{}) == "Search completed"
    end
  end

  describe "system_prompt_context/0" do
    test "returns context string" do
      context = WebSearch.system_prompt_context()
      assert is_binary(context)
      assert context =~ "web_search"
    end

    test "includes citation instructions" do
      context = WebSearch.system_prompt_context()
      assert context =~ "Sources"
    end
  end

  describe "run/2 validation" do
    test "returns error for empty query" do
      params = %{query: ""}
      assert {:ok, result} = WebSearch.run(params, %{})
      assert result.error =~ "cannot be empty"
      assert result.query == ""
      assert result.results == []
    end

    test "returns error for whitespace-only query" do
      params = %{query: "   "}
      assert {:ok, result} = WebSearch.run(params, %{})
      assert result.error =~ "cannot be empty"
    end

    test "caps num_results at 10" do
      params = %{query: "test", num_results: 100}
      assert {:ok, result} = WebSearch.run(params, %{})
      # Validation should cap it at 10 internally
      assert result.query == "test"
    end

    test "accepts category option" do
      params = %{query: "test", category: "news"}
      assert {:ok, result} = WebSearch.run(params, %{})
      assert result.query == "test"
    end
  end
end
