defmodule Magus.Models.CatalogTest do
  use ExUnit.Case, async: true

  alias Magus.Models.Catalog

  describe "OSS empty-start (magus-mxj5.6)" do
    test "the open-core catalog ships empty" do
      assert Catalog.all() == []
      assert Catalog.all_with_internal() == []
    end
  end

  # The curated data moved to MagusCloud.Models.Catalog; the transformers stay
  # in core because the data-migration helpers (Backfill / InternalizeExtras)
  # use them. They operate on caller-supplied entries, so they are exercised
  # here with inline fixtures rather than the (now empty) catalog list.
  describe "to_db_attrs/1" do
    test "drops llmdb_* and seed? fields and any unknown keys" do
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

    test "folds llmdb_* overrides into derived llm_metadata" do
      entry = %{name: "X", key: "openrouter:x/y", provider: "X Corp", llmdb_output_limit: 1234}
      attrs = Catalog.to_db_attrs(entry)
      assert attrs.llm_metadata == %{"output_limit" => 1234}
      assert attrs.name == "X"
    end

    test "returns only keys the Magus.Chat.Model :create action accepts" do
      accept_keys =
        Magus.Chat.Model
        |> Ash.Resource.Info.action(:create)
        |> Map.fetch!(:accept)
        |> MapSet.new()

      attrs = Catalog.to_db_attrs(%{name: "Z", key: "openrouter:z", provider: "Z"})
      unknown = MapSet.difference(MapSet.new(Map.keys(attrs)), accept_keys)
      assert MapSet.size(unknown) == 0, "unexpected keys: #{inspect(MapSet.to_list(unknown))}"
    end
  end

  describe "to_llm_metadata/1" do
    test "extracts llmdb overrides into a string-keyed map" do
      entry = %{
        key: "openrouter:x/y",
        llmdb_output_limit: 32_000,
        llmdb_cache_read: 0.5,
        llmdb_cache_write: 6.25,
        llmdb_skip_tools?: true
      }

      assert Catalog.to_llm_metadata(entry) == %{
               "output_limit" => 32_000,
               "cache_read" => 0.5,
               "cache_write" => 6.25,
               "skip_tools" => true
             }
    end
  end

  describe "llmdb_provider_meta/1" do
    test "returns provider metadata for a known slug" do
      meta = Catalog.llmdb_provider_meta("openrouter")
      assert meta.req_llm_id == "openrouter"
      assert meta.base_url == "https://openrouter.ai/api/v1"
    end
  end
end
