defmodule Magus.Sandbox.SandboxTest do
  use Magus.DataCase, async: true

  alias Magus.Sandbox
  alias Magus.Chat

  describe "Sandbox creation" do
    setup do
      user = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)
      %{user: user, conversation: conversation}
    end

    test "creates sandbox in uninitialized state", %{conversation: conversation} do
      {:ok, sandbox} = Sandbox.create_sandbox(conversation.id, authorize?: false)

      assert sandbox.state == :uninitialized
      assert sandbox.conversation_id == conversation.id
      assert sandbox.sprite_id == nil
      assert sandbox.installed_packages == []
      assert sandbox.total_executions == 0
    end

    test "enforces unique conversation constraint", %{conversation: conversation} do
      {:ok, _sandbox1} = Sandbox.create_sandbox(conversation.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Sandbox.create_sandbox(conversation.id, authorize?: false)
    end
  end

  describe "Sandbox authorization" do
    setup do
      user1 = create_user()
      user2 = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user1)
      {:ok, sandbox} = Sandbox.create_sandbox(conversation.id, authorize?: false)
      %{user1: user1, user2: user2, conversation: conversation, sandbox: sandbox}
    end

    test "owner can read their sandbox", %{user1: user1, sandbox: sandbox} do
      {:ok, [found]} =
        Sandbox.get_sandbox_by_conversation(sandbox.conversation_id, actor: user1)

      assert found.id == sandbox.id
    end

    test "non-owner cannot read sandbox", %{user2: user2, sandbox: sandbox} do
      {:ok, result} =
        Sandbox.get_sandbox_by_conversation(sandbox.conversation_id, actor: user2)

      assert result == []
    end

    test "OwnsConversation check prevents creating sandbox for other user's conversation", %{
      user2: user2,
      conversation: conversation
    } do
      # Delete existing sandbox first
      {:ok, [sandbox]} =
        Sandbox.get_sandbox_by_conversation(conversation.id, authorize?: false)

      :ok = Ash.destroy(sandbox, authorize?: false)

      # Try to create sandbox as non-owner
      assert {:error, %Ash.Error.Forbidden{}} =
               Sandbox.create_sandbox(conversation.id, actor: user2)
    end
  end

  describe "Sandbox state transitions" do
    setup do
      user = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)
      {:ok, sandbox} = Sandbox.create_sandbox(conversation.id, authorize?: false)
      %{user: user, sandbox: sandbox}
    end

    test "record_execution updates stats", %{sandbox: sandbox} do
      # Record an execution (sandbox doesn't need to be provisioned for this)
      {:ok, updated} =
        Sandbox.record_execution(sandbox, 1500, Decimal.new("0.001"), authorize?: false)

      assert updated.total_executions == 1
      assert Decimal.compare(updated.total_cost_usd, Decimal.new("0.001")) == :eq
      assert updated.last_executed_at != nil
    end

    test "add_package tracks installed packages", %{sandbox: sandbox} do
      {:ok, updated1} = Sandbox.add_package(sandbox, "numpy", authorize?: false)
      assert "numpy" in updated1.installed_packages

      {:ok, updated2} = Sandbox.add_package(updated1, "pandas", authorize?: false)
      assert "numpy" in updated2.installed_packages
      assert "pandas" in updated2.installed_packages
    end

    test "add_package is idempotent", %{sandbox: sandbox} do
      {:ok, updated1} = Sandbox.add_package(sandbox, "numpy", authorize?: false)
      {:ok, updated2} = Sandbox.add_package(updated1, "numpy", authorize?: false)

      assert length(updated2.installed_packages) == 1
    end
  end

  # Helper functions

  defp create_user do
    {:ok, user} =
      Magus.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "test-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!",
        password_confirmation: "ValidPassword123!",
        name: "Test User",
        accepted_terms: true,
        accepted_age_requirement: true
      })
      |> Ash.create(authorize?: false)

    user
  end
end
