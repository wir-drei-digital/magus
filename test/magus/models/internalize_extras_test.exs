defmodule Magus.Models.InternalizeExtrasTest do
  use Magus.DataCase, async: false

  alias Magus.Models.InternalizeExtras

  test "creates citations provider and internal utility models, idempotently" do
    assert :ok = InternalizeExtras.run()
    assert :ok = InternalizeExtras.run()

    {:ok, citations} = Magus.Models.get_provider_by_slug("openrouter_citations")
    assert citations.req_llm_id == "openrouter_citations"

    models = Ash.read!(Magus.Chat.Model, authorize?: false)
    internal = Enum.filter(models, & &1.internal?)

    internal_keys = MapSet.new(internal, & &1.key)

    # every legacy seed?: false catalog entry + the citations model exists internal
    legacy_only =
      Magus.Models.Catalog.all_with_internal()
      |> Enum.filter(&(Map.get(&1, :seed?, true) == false))

    assert legacy_only != []

    for entry <- legacy_only do
      assert MapSet.member?(internal_keys, entry.key), "missing internal row for #{entry.key}"
    end

    # the citations Sonar model exists as an internal row too
    assert MapSet.member?(internal_keys, "openrouter_citations:perplexity/sonar-pro-search")

    # all internal rows are provider-linked and active (LLMDB needs them)
    for model <- internal do
      assert model.active?
      assert model.model_provider_id
    end
  end

  test "internal models are excluded from the user-facing active list" do
    :ok = InternalizeExtras.run()
    active = Magus.Chat.list_active_models!()
    refute Enum.any?(active, & &1.internal?)
  end

  test "CatalogSync.build_custom includes internal models" do
    :ok = InternalizeExtras.run()
    custom = Magus.Models.CatalogSync.build_custom()

    assert custom[:openrouter_citations][:models] != %{}
    assert get_in(custom, [:openrouter])[:models]["mistralai/ministral-3b-2512"]
  end
end
