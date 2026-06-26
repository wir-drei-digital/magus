defmodule Magus.SuperBrain.EmbeddingConfigTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.EmbeddingConfig

  describe "dim/0" do
    test "returns 1536 (text-embedding-3-small)" do
      assert EmbeddingConfig.dim() == 1536
    end
  end

  describe "embedder/0" do
    test "returns the configured embedder module" do
      expected = Application.fetch_env!(:magus, :super_brain_embedder)
      assert EmbeddingConfig.embedder() == expected
    end
  end

  describe "index_name/1" do
    test "bakes the embedding dim into the index name for Entity" do
      assert EmbeddingConfig.index_name("Entity") == "Entity__embedding__1536"
    end

    test "bakes the embedding dim into the index name for CanonicalEntity" do
      assert EmbeddingConfig.index_name("CanonicalEntity") ==
               "CanonicalEntity__embedding__1536"
    end

    test "uses the current dim/0 value rather than a literal" do
      # Sanity check: if dim/0 ever changes, the index name follows.
      assert String.ends_with?(
               EmbeddingConfig.index_name("Whatever"),
               "__#{EmbeddingConfig.dim()}"
             )
    end
  end
end
