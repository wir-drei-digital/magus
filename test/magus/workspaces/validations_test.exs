defmodule Magus.Workspaces.ValidationsTest do
  use Magus.DataCase, async: true

  test "ParentInSameWorkspace module exports validate/3" do
    assert function_exported?(Magus.Workspaces.Validations.ParentInSameWorkspace, :validate, 3)
  end

  test "FolderInSameWorkspace module exports validate/3" do
    assert function_exported?(Magus.Workspaces.Validations.FolderInSameWorkspace, :validate, 3)
  end

  test "BroadcastHelpers module exports broadcast_user/3" do
    assert function_exported?(Magus.Workspaces.BroadcastHelpers, :broadcast_user, 3)
  end

  test "DestroyResourceGrants module exports change/3" do
    assert function_exported?(Magus.Workspaces.Changes.DestroyResourceGrants, :change, 3)
  end
end
