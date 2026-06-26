defmodule Magus.Models.CatalogTest do
  use ExUnit.Case, async: true

  alias Magus.Models.Catalog

  describe "all/0" do
    test "filters out seed?: false entries" do
      entries = Catalog.all()
      refute Enum.any?(entries, &(Map.get(&1, :seed?, true) == false))
    end

    test "every entry has a key" do
      for entry <- Catalog.all() do
        assert is_binary(entry[:key]), "missing key: #{inspect(entry)}"
      end
    end

    test "all_with_internal/0 includes seed?: false entries" do
      assert length(Catalog.all_with_internal()) > length(Catalog.all())
    end
  end

  describe "to_db_attrs/1" do
    test "produces only fields the Magus.Chat.Model :create action accepts" do
      accept_keys =
        Magus.Chat.Model
        |> Ash.Resource.Info.action(:create)
        |> Map.fetch!(:accept)
        |> MapSet.new()

      for entry <- Catalog.all() do
        attrs = Catalog.to_db_attrs(entry)
        unknown = MapSet.difference(MapSet.new(Map.keys(attrs)), accept_keys)

        assert MapSet.size(unknown) == 0,
               "to_db_attrs/1 returned keys not in :create accept list for " <>
                 "#{entry[:key]}: #{inspect(MapSet.to_list(unknown))}"
      end
    end

    test "drops llmdb_* and seed? fields" do
      entry = %{
        name: "Test",
        key: "test:foo",
        provider: "Test",
        seed?: false,
        llmdb_provider: :openrouter,
        llmdb_model_id: "foo",
        llmdb_output_limit: 32_000,
        random_unknown_key: "ignored"
      }

      attrs = Catalog.to_db_attrs(entry)
      refute Map.has_key?(attrs, :seed?)
      refute Map.has_key?(attrs, :llmdb_provider)
      refute Map.has_key?(attrs, :llmdb_model_id)
      refute Map.has_key?(attrs, :llmdb_output_limit)
      refute Map.has_key?(attrs, :random_unknown_key)
      assert attrs.name == "Test"
      assert attrs.key == "test:foo"
    end

    test "to_db_attrs includes derived llm_metadata" do
      entry = %{
        name: "X",
        key: "openrouter:x/y",
        provider: "X Corp",
        llmdb_output_limit: 1234
      }

      attrs = Magus.Models.Catalog.to_db_attrs(entry)
      assert attrs.llm_metadata == %{"output_limit" => 1234}
      assert attrs.name == "X"
    end
  end

  describe "to_llm_metadata/1" do
    test "Catalog.to_llm_metadata extracts llmdb overrides from a catalog entry" do
      entry = %{
        key: "openrouter:x/y",
        llmdb_output_limit: 32_000,
        llmdb_cache_read: 0.5,
        llmdb_cache_write: 6.25,
        llmdb_skip_tools?: true
      }

      assert Magus.Models.Catalog.to_llm_metadata(entry) == %{
               "output_limit" => 32_000,
               "cache_read" => 0.5,
               "cache_write" => 6.25,
               "skip_tools" => true
             }
    end
  end

  describe "to_db_attrs/1 api_provider" do
    test "Apertus 70B db attrs preserve api_provider: :publicai" do
      apertus =
        Catalog.all()
        |> Enum.find(&(&1.key == "publicai:swiss-ai/apertus-70b-instruct"))

      attrs = Catalog.to_db_attrs(apertus)
      assert attrs.api_provider == :publicai
      assert attrs.provider == "Swiss AI"
    end
  end
end
