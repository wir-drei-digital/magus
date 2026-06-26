defmodule Magus.Memory.MemoryWorkspaceTest do
  @moduledoc "Workspace isolation for the Memory resource."
  use Magus.ResourceCase, async: true

  alias Magus.Memory
  alias Magus.Chat

  defp pro_user do
    user = generate(user())
    ensure_workspace_plan(user)
    user
  end

  defp ws(actor), do: generate(workspace(actor: actor))

  describe ":local memories derive workspace_id from the conversation" do
    test "local memory inherits conversation.workspace_id" do
      user = pro_user()
      ws = ws(user)
      {:ok, conv} = Chat.create_conversation(%{workspace_id: ws.id}, actor: user)

      {:ok, memory} =
        Memory.create_memory(conv.id, user.id, "task", %{summary: "hi"}, actor: user)

      assert memory.workspace_id == ws.id
    end

    test "local memory in a personal conversation has nil workspace_id" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(conv.id, user.id, "task", %{summary: "hi"}, actor: user)

      assert is_nil(memory.workspace_id)
    end
  end

  describe ":agent memories derive workspace_id from the custom agent" do
    test "agent memory inherits custom_agent.workspace_id" do
      user = pro_user()
      ws = ws(user)

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "ws-agent", instructions: "do stuff", workspace_id: ws.id},
          actor: user
        )

      {:ok, memory} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "pref", summary: "x"},
          actor: user
        )

      assert memory.workspace_id == ws.id
      assert memory.scope == :agent
    end
  end

  describe ":user memories accept an explicit workspace_id" do
    test "create_user_memory stores workspace_id" do
      user = pro_user()
      ws = ws(user)

      {:ok, memory} =
        Memory.create_user_memory(user.id, ws.id, "pref", %{summary: "x"}, actor: user)

      assert memory.workspace_id == ws.id
      assert memory.scope == :user
    end

    test "create_user_memory with nil workspace_id stays personal" do
      user = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(user.id, nil, "pref", %{summary: "x"}, actor: user)

      assert is_nil(memory.workspace_id)
    end

    test "same name allowed in two different workspaces" do
      user = pro_user()
      ws1 = ws(user)
      ws2 = ws(user)

      {:ok, _} =
        Memory.create_user_memory(user.id, ws1.id, "pref", %{summary: "a"}, actor: user)

      {:ok, _} =
        Memory.create_user_memory(user.id, ws2.id, "pref", %{summary: "b"}, actor: user)
    end

    test "same name twice in the same workspace fails" do
      user = pro_user()
      ws = ws(user)

      {:ok, _} =
        Memory.create_user_memory(user.id, ws.id, "pref", %{summary: "a"}, actor: user)

      assert {:error, _} =
               Memory.create_user_memory(user.id, ws.id, "pref", %{summary: "b"}, actor: user)
    end

    test "same name once in personal and once in workspace both succeed" do
      user = pro_user()
      ws = ws(user)

      {:ok, _} =
        Memory.create_user_memory(user.id, nil, "pref", %{summary: "a"}, actor: user)

      {:ok, _} =
        Memory.create_user_memory(user.id, ws.id, "pref", %{summary: "b"}, actor: user)
    end
  end

  describe "promote_to_user" do
    test "carries the source local memory's workspace_id" do
      user = pro_user()
      ws = ws(user)
      {:ok, conv} = Chat.create_conversation(%{workspace_id: ws.id}, actor: user)
      {:ok, local} = Memory.create_memory(conv.id, user.id, "tip", %{summary: "x"}, actor: user)

      {:ok, promoted} = Memory.promote_memory_to_user(local, actor: user)

      assert promoted.scope == :user
      assert promoted.workspace_id == ws.id
      assert is_nil(promoted.conversation_id)
    end
  end

  describe ":user memories are isolated per workspace on read" do
    setup do
      user = pro_user()
      ws1 = ws(user)
      ws2 = ws(user)

      {:ok, m1} =
        Memory.create_user_memory(user.id, ws1.id, "pref", %{summary: "ws1"}, actor: user)

      {:ok, m2} =
        Memory.create_user_memory(user.id, ws2.id, "pref", %{summary: "ws2"}, actor: user)

      {:ok, mp} =
        Memory.create_user_memory(user.id, nil, "pref", %{summary: "personal"}, actor: user)

      %{user: user, ws1: ws1, ws2: ws2, m1: m1, m2: m2, mp: mp}
    end

    test "list_user_memories returns only ws1 memories", %{user: user, ws1: ws1, m1: m1} do
      {:ok, memories} = Memory.list_user_memories(ws1.id, actor: user)
      assert Enum.map(memories, & &1.id) == [m1.id]
    end

    test "list_user_memories with nil returns only personal", %{user: user, mp: mp} do
      {:ok, memories} = Memory.list_user_memories(nil, actor: user)
      assert Enum.map(memories, & &1.id) == [mp.id]
    end

    test "get_user_memory_by_name scopes by workspace", %{user: user, ws1: ws1, m1: m1} do
      {:ok, found} = Memory.get_user_memory_by_name(ws1.id, "pref", actor: user)
      assert found.id == m1.id
    end

    test "list_top_user is workspace-scoped", %{user: user, ws2: ws2, m2: m2} do
      {:ok, memories} = Memory.list_top_user(ws2.id, actor: user)
      assert Enum.map(memories, & &1.id) == [m2.id]
    end
  end
end
