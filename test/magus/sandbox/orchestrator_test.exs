defmodule Magus.Sandbox.OrchestratorTest do
  use Magus.DataCase, async: true

  alias Magus.Sandbox.Orchestrator
  alias Magus.Chat

  describe "execute/3 authorization" do
    setup do
      user1 = create_user()
      user2 = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "User1 Conv"}, actor: user1)
      %{user1: user1, user2: user2, conversation: conversation}
    end

    test "rejects execution for non-owner user", %{user2: user2, conversation: conversation} do
      # Ash policies filter unauthorized records and return not_found for security
      # (to avoid revealing whether the resource exists)
      assert {:error, :not_found, _msg} =
               Orchestrator.execute(
                 conversation.id,
                 "print('hello')",
                 user_id: user2.id
               )
    end

    test "rejects execution without user_id", %{conversation: conversation} do
      # user_id is required for sandbox execution
      assert {:error, :unauthorized, msg} =
               Orchestrator.execute(conversation.id, "print('hello')", [])

      assert msg =~ "user_id is required"
    end

    test "rejects execution for non-existent conversation" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found, _} =
               Orchestrator.execute(
                 fake_id,
                 "print('hello')",
                 user_id: Ecto.UUID.generate()
               )
    end
  end

  describe "sandbox_lock/2 advisory locking" do
    setup do
      user = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Lock Test"}, actor: user)
      %{user: user, conversation: conversation}
    end

    test "sandbox_lock serializes access and returns callback result", %{
      conversation: conversation
    } do
      result =
        Magus.Repo.transaction(fn ->
          Orchestrator.sandbox_lock(conversation.id, fn ->
            :lock_acquired
          end)
        end)

      assert {:ok, :lock_acquired} = result
    end
  end

  describe "upload_file/3 authorization" do
    setup do
      user1 = create_user()
      user2 = create_user()
      {:ok, conversation} = Chat.create_conversation(%{title: "Upload Test"}, actor: user1)
      %{user1: user1, user2: user2, conversation: conversation}
    end

    test "rejects upload without user_id", %{conversation: conversation} do
      assert {:error, :unauthorized, msg} =
               Orchestrator.upload_file(conversation.id, {:file_id, Ecto.UUID.generate()}, [])

      assert msg =~ "user_id is required"
    end

    test "rejects upload for non-owner user", %{user2: user2, conversation: conversation} do
      assert {:error, :not_found, _msg} =
               Orchestrator.upload_file(
                 conversation.id,
                 {:file_id, Ecto.UUID.generate()},
                 user_id: user2.id
               )
    end

    test "returns error for non-existent file_id", %{user1: user1, conversation: conversation} do
      fake_file_id = Ecto.UUID.generate()

      assert {:error, :not_found, msg} =
               Orchestrator.upload_file(
                 conversation.id,
                 {:file_id, fake_file_id},
                 user_id: user1.id
               )

      assert msg =~ "File not found"
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
