defmodule Magus.Memory.MemoryUserRpcPolicyTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  test "a user reads only their own user-scope memories via user_for_user" do
    user = generate(user())
    other = generate(user())

    {:ok, _} =
      Magus.Memory.create_user_memory(user.id, nil, "Mine", %{content: %{}, summary: "mine"},
        actor: %Magus.Agents.Support.AiAgent{}
      )

    {:ok, mine} =
      Magus.Memory.Memory
      |> Ash.Query.for_read(:user_for_user, %{workspace_id: nil}, actor: user)
      |> Ash.read()

    assert Enum.all?(mine, &(&1.user_id == user.id))

    {:ok, theirs} =
      Magus.Memory.Memory
      |> Ash.Query.for_read(:user_for_user, %{workspace_id: nil}, actor: other)
      |> Ash.read()

    refute Enum.any?(theirs, &(&1.user_id == user.id))
  end

  test "a user can destroy their own memory but not another's" do
    user = generate(user())
    other = generate(user())

    {:ok, mem} =
      Magus.Memory.create_user_memory(user.id, nil, "Mine", %{content: %{}, summary: "mine"},
        actor: %Magus.Agents.Support.AiAgent{}
      )

    assert {:error, _} =
             mem |> Ash.Changeset.for_destroy(:destroy, %{}, actor: other) |> Ash.destroy()

    assert :ok =
             mem |> Ash.Changeset.for_destroy(:destroy, %{}, actor: user) |> Ash.destroy()
  end
end
