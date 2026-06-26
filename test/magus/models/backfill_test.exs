defmodule Magus.Models.BackfillTest do
  use Magus.DataCase, async: false

  alias Magus.Models.Backfill

  test "creates provider rows for each distinct api_provider and links models" do
    {:ok, _} =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Catalog Model",
        # real key from the catalog so llm_metadata backfill matches
        key: "openrouter:anthropic/claude-sonnet-4.6",
        provider: "Anthropic",
        api_provider: :openrouter,
        context_window: 1_000_000
      })
      |> Ash.create()

    {:ok, _} =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "xAI Model",
        key: "xai:grok-test",
        provider: "xAI",
        api_provider: :xai,
        context_window: 100_000
      })
      |> Ash.create()

    assert :ok = Backfill.run()

    {:ok, openrouter} = Magus.Models.get_provider_by_slug("openrouter")
    {:ok, xai} = Magus.Models.get_provider_by_slug("xai")
    assert openrouter.req_llm_id == "openrouter"
    assert xai.req_llm_id == "xai"

    models = Ash.read!(Magus.Chat.Model)
    sonnet = Enum.find(models, &(&1.key == "openrouter:anthropic/claude-sonnet-4.6"))
    grok = Enum.find(models, &(&1.key == "xai:grok-test"))

    assert sonnet.model_provider_id == openrouter.id
    assert grok.model_provider_id == xai.id

    # llm_metadata pulled from the catalog entry for the matching key
    assert sonnet.llm_metadata["output_limit"] == 128_000
    # not in catalog -> stays empty
    assert grok.llm_metadata == %{}
  end

  test "run is idempotent" do
    {:ok, _} =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Idempotency Model",
        key: "openrouter:test/idem",
        provider: "Test",
        api_provider: :openrouter,
        context_window: 100_000
      })
      |> Ash.create()

    assert :ok = Backfill.run()
    assert :ok = Backfill.run()
    assert {:ok, _} = Magus.Models.get_provider_by_slug("openrouter")
  end

  test "does not overwrite existing llm_metadata" do
    {:ok, model} =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Pre-set Metadata",
        key: "openrouter:anthropic/claude-sonnet-4.6",
        provider: "Anthropic",
        api_provider: :openrouter,
        context_window: 1_000_000,
        llm_metadata: %{"output_limit" => 9_999}
      })
      |> Ash.create()

    assert :ok = Backfill.run()

    updated = Ash.get!(Magus.Chat.Model, model.id)
    assert updated.llm_metadata == %{"output_limit" => 9_999}
  end
end
