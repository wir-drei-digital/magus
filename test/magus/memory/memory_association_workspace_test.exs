defmodule Magus.Memory.MemoryAssociationWorkspaceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Memory

  defp pro_user do
    user = generate(user())
    ensure_workspace_plan(user)
    user
  end

  test "rejects associations across workspaces" do
    user = pro_user()
    ws1 = generate(workspace(actor: user))
    ws2 = generate(workspace(actor: user))

    {:ok, m1} = Memory.create_user_memory(user.id, ws1.id, "n1", %{summary: "x"}, actor: user)
    {:ok, m2} = Memory.create_user_memory(user.id, ws2.id, "n2", %{summary: "y"}, actor: user)

    assert {:error, _} =
             Memory.create_memory_association(m1.id, m2.id, %{weight: 0.5}, authorize?: false)
  end

  test "allows associations within the same workspace" do
    user = pro_user()
    ws = generate(workspace(actor: user))

    {:ok, m1} = Memory.create_user_memory(user.id, ws.id, "n1", %{summary: "x"}, actor: user)
    {:ok, m2} = Memory.create_user_memory(user.id, ws.id, "n2", %{summary: "y"}, actor: user)

    assert {:ok, _} =
             Memory.create_memory_association(m1.id, m2.id, %{weight: 0.5}, authorize?: false)
  end

  test "allows associations within personal context" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{}, actor: user)

    {:ok, m1} = Memory.create_memory(conv.id, user.id, "n1", %{summary: "x"}, actor: user)
    {:ok, m2} = Memory.create_memory(conv.id, user.id, "n2", %{summary: "y"}, actor: user)

    assert {:ok, _} =
             Memory.create_memory_association(m1.id, m2.id, %{weight: 0.5}, authorize?: false)
  end
end
