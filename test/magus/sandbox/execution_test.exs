defmodule Magus.Sandbox.ExecutionTest do
  use Magus.DataCase, async: true

  alias Magus.Sandbox
  alias Magus.Chat

  describe "Execution creation" do
    setup do
      user = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)
      {:ok, sandbox} = Sandbox.create_sandbox(conversation.id, authorize?: false)
      %{user: user, conversation: conversation, sandbox: sandbox}
    end

    test "creates execution in pending state", %{sandbox: sandbox} do
      {:ok, execution} =
        Sandbox.create_execution(
          %{code: "print('hello')", sandbox_id: sandbox.id},
          authorize?: false
        )

      assert execution.status == :pending
      assert execution.code == "print('hello')"
      assert execution.sandbox_id == sandbox.id
    end

    test "transitions through status states", %{sandbox: sandbox} do
      {:ok, execution} =
        Sandbox.create_execution(
          %{code: "x = 1 + 2", sandbox_id: sandbox.id},
          authorize?: false
        )

      assert execution.status == :pending

      {:ok, started} = Sandbox.start_execution(execution, authorize?: false)
      assert started.status == :running

      {:ok, completed} =
        Sandbox.complete_execution(
          started,
          %{
            stdout: "3",
            stderr: "",
            exit_code: 0,
            duration_ms: 100,
            estimated_cost_usd: Decimal.new("0.001")
          },
          authorize?: false
        )

      assert completed.status == :completed
      assert completed.stdout == "3"
      assert completed.exit_code == 0
    end

    test "can transition to failed state", %{sandbox: sandbox} do
      {:ok, execution} =
        Sandbox.create_execution(
          %{code: "invalid python", sandbox_id: sandbox.id},
          authorize?: false
        )

      {:ok, started} = Sandbox.start_execution(execution, authorize?: false)

      {:ok, failed} =
        Sandbox.fail_execution(
          started,
          %{
            stdout: "",
            stderr: "SyntaxError: invalid syntax",
            exit_code: 1,
            duration_ms: 50,
            error_type: :syntax_error
          },
          authorize?: false
        )

      assert failed.status == :failed
      assert failed.error_type == :syntax_error
    end

    test "can transition to timeout state", %{sandbox: sandbox} do
      {:ok, execution} =
        Sandbox.create_execution(
          %{code: "while True: pass", sandbox_id: sandbox.id},
          authorize?: false
        )

      {:ok, started} = Sandbox.start_execution(execution, authorize?: false)

      {:ok, timed_out} =
        Sandbox.timeout_execution(
          started,
          %{stdout: "", stderr: "Timed out", duration_ms: 30_000},
          authorize?: false
        )

      assert timed_out.status == :timeout
      assert timed_out.error_type == :timeout
    end
  end

  describe "Execution authorization" do
    setup do
      user1 = create_user()
      user2 = create_user()
      {:ok, conversation1} = Chat.create_conversation(%{title: "User1 Conv"}, actor: user1)
      {:ok, conversation2} = Chat.create_conversation(%{title: "User2 Conv"}, actor: user2)
      {:ok, sandbox1} = Sandbox.create_sandbox(conversation1.id, authorize?: false)
      {:ok, sandbox2} = Sandbox.create_sandbox(conversation2.id, authorize?: false)

      {:ok, execution1} =
        Sandbox.create_execution(
          %{code: "print('user1')", sandbox_id: sandbox1.id},
          authorize?: false
        )

      %{
        user1: user1,
        user2: user2,
        sandbox1: sandbox1,
        sandbox2: sandbox2,
        execution1: execution1
      }
    end

    test "owner can read their execution", %{user1: user1, execution1: execution1} do
      {:ok, found} = Sandbox.get_execution(execution1.id, actor: user1)
      assert found.id == execution1.id
    end

    test "non-owner cannot read execution", %{user2: user2, execution1: execution1} do
      # Ash wraps NotFound in Invalid for policy-filtered reads
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Sandbox.get_execution(execution1.id, actor: user2)
    end

    test "OwnsSandbox check prevents creating execution for other user's sandbox", %{
      user1: user1,
      sandbox2: sandbox2
    } do
      # user1 tries to create execution in user2's sandbox
      assert {:error, %Ash.Error.Forbidden{}} =
               Sandbox.create_execution(
                 %{code: "print('hacked')", sandbox_id: sandbox2.id},
                 actor: user1
               )
    end

    test "owner can create execution in their own sandbox", %{user1: user1, sandbox1: sandbox1} do
      {:ok, execution} =
        Sandbox.create_execution(
          %{code: "print('allowed')", sandbox_id: sandbox1.id},
          actor: user1
        )

      assert execution.sandbox_id == sandbox1.id
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
