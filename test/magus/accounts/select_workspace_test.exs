defmodule Magus.Accounts.SelectWorkspaceTest do
  use Magus.ResourceCase, async: true

  test "select_workspace allows nil and active member workspaces only" do
    user = generate(user())
    other_user = generate(user())
    ensure_workspace_plan(user)
    ensure_workspace_plan(other_user)

    workspace = generate(workspace(actor: user))
    other_workspace = generate(workspace(actor: other_user))

    assert {:ok, updated} = Magus.Accounts.select_workspace(user, workspace.id, actor: user)
    assert updated.current_workspace_id == workspace.id

    assert {:error, %Ash.Error.Invalid{}} =
             Magus.Accounts.select_workspace(user, other_workspace.id, actor: user)

    assert {:ok, cleared} = Magus.Accounts.select_workspace(updated, nil, actor: user)
    assert is_nil(cleared.current_workspace_id)
  end
end
