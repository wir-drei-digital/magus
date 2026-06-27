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
end
