defmodule Magus.Models.SyncTriggerTest do
  use Magus.DataCase, async: false

  test "SyncCatalog change is attached to provider and model write actions" do
    for {resource, actions} <- [
          {Magus.Models.Provider, [:create, :update, :destroy]},
          {Magus.Chat.Model, [:create, :update, :destroy]}
        ],
        action_name <- actions do
      action = Ash.Resource.Info.action(resource, action_name)

      # the change is attached resource-globally; action-local lists also checked
      changes = action.changes ++ Ash.Resource.Info.changes(resource)

      assert Enum.any?(changes, fn
               %{change: {Magus.Models.Changes.SyncCatalog, _}} -> true
               _ -> false
             end),
             "#{inspect(resource)} #{action_name} missing SyncCatalog change"
    end
  end

  test "DB extras: internalized LLMDB-only entries and citations provider appear in build_custom" do
    :ok = Magus.Models.InternalizeExtras.run()

    custom = Magus.Models.CatalogSync.build_custom()

    # openrouter_citations provider now a real DB provider row
    assert custom[:openrouter_citations][:base_url] == "https://openrouter.ai/api/v1"

    # every legacy seed?: false entry is present, now as an internal DB row
    legacy_only =
      Magus.Models.Catalog.all_with_internal()
      |> Enum.filter(&(Map.get(&1, :seed?, true) == false))

    assert legacy_only != []

    for entry <- legacy_only do
      provider = entry.llmdb_provider

      assert get_in(custom, [provider])[:models][entry.llmdb_model_id],
             "missing internalized entry #{entry.key}"
    end
  end

  test "internalized ministral row appears in build_custom" do
    :ok = Magus.Models.InternalizeExtras.run()

    custom = Magus.Models.CatalogSync.build_custom()
    entry = custom[:openrouter][:models]["mistralai/ministral-3b-2512"]

    assert entry.name == "Ministral 3B 2512"
  end
end
