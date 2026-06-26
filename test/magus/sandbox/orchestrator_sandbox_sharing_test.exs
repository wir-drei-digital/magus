defmodule Magus.Sandbox.OrchestratorSandboxSharingTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Sandbox.Orchestrator

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    child =
      Magus.Chat.create_conversation!(
        %{
          is_task_conversation: true,
          parent_conversation_id: parent.id,
          sandbox_conversation_id: parent.id
        },
        actor: user
      )

    %{user: user, parent: parent, child: child}
  end

  describe "resolve_effective_conversation_id/1" do
    test "returns sandbox_conversation_id when set", %{parent: parent, child: child} do
      assert Orchestrator.resolve_effective_conversation_id(child.id) == parent.id
    end

    test "returns own id when sandbox_conversation_id is nil", %{parent: parent} do
      assert Orchestrator.resolve_effective_conversation_id(parent.id) == parent.id
    end

    test "handles chained resolution (grandchild points to root)", %{user: user, parent: root} do
      mid =
        Magus.Chat.create_conversation!(
          %{
            is_task_conversation: true,
            parent_conversation_id: root.id,
            sandbox_conversation_id: root.id
          },
          actor: user
        )

      grandchild =
        Magus.Chat.create_conversation!(
          %{
            is_task_conversation: true,
            parent_conversation_id: mid.id,
            sandbox_conversation_id: root.id
          },
          actor: user
        )

      assert Orchestrator.resolve_effective_conversation_id(grandchild.id) == root.id
    end
  end

  describe "resolve_and_authorize (via read_file)" do
    test "child conversation resolves to parent's sandbox conversation", %{
      user: user,
      child: child
    } do
      # read_file will fail with :not_configured (no sandbox provider in test)
      # but it should NOT fail with :not_found, proving authorization passed
      result = Orchestrator.read_file(child.id, "/workspace/test.txt", user_id: user.id)

      # Either :not_configured (no provider) or :sandbox_error -- not :not_found or :unauthorized
      assert match?({:error, _, _}, result)
      {_, error_type, _} = result
      refute error_type == :not_found
      refute error_type == :unauthorized
    end

    test "returns error when user_id is missing" do
      result = Orchestrator.read_file(Ash.UUID.generate(), "/test.txt", [])
      assert {:error, :unauthorized, _} = result
    end

    test "returns not_found for non-existent conversation", %{user: user} do
      result =
        Orchestrator.read_file(Ash.UUID.generate(), "/test.txt", user_id: user.id)

      assert {:error, :not_found, _} = result
    end
  end
end
