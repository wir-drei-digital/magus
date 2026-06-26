defmodule Magus.BrainTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  describe "list_brains_for_workspace/1" do
    test "returns workspace brains visible to the actor" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, ws_brain} =
        Magus.Brain.create_brain(
          %{title: "WS Brain", workspace_id: ws.id},
          actor: user
        )

      {:ok, _personal_brain} =
        Magus.Brain.create_brain(%{title: "Personal Brain"}, actor: user)

      brains = Magus.Brain.list_brains_for_workspace!(ws.id, actor: user)

      ids = Enum.map(brains, & &1.id)
      assert ws_brain.id in ids
      refute Enum.any?(brains, fn b -> b.title == "Personal Brain" end)
    end
  end
end
