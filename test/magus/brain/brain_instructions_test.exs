defmodule Magus.Brain.BrainInstructionsTest do
  # NOTE: Brief specified `Magus.AccountsFixtures.user_fixture()`, but that module
  # does not exist in this codebase; sibling brain tests use `Magus.Generators`
  # (see test/magus/brain/brain_test.exs). Behavior asserted is identical to the brief.
  use Magus.DataCase, async: true
  import Magus.Generators

  test "set_instructions updates only the constitution" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Research"}, actor: user)

    {:ok, updated} =
      Magus.Brain.set_brain_instructions(brain, %{instructions: "Atomic pages only."},
        actor: user
      )

    assert updated.instructions == "Atomic pages only."
  end
end
