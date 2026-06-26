defmodule Magus.Oban.TriggersTest do
  @moduledoc """
  Tests for Oban job triggers across Ash resources.

  Verifies that actions properly enqueue background jobs for:
  - Message response generation
  - Conversation name generation
  - File processing

  Note: Some actions use `authorize?: false` because they trigger internal
  system operations (Oban jobs) that don't have user-facing authorization,
  or because the resources involved (Message, File) don't have authorization policies.
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.Chat
  alias Magus.Files
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  # Minimal valid PNG for file tests
  @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
                 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
                 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
                 0x60, 0x82>>
  @ai_agent %Magus.Agents.Support.AiAgent{}

  # Note: The Message respond trigger was replaced by the Jido agent system.
  # User messages now signal a Jido conversation agent via SignalAgent change
  # instead of enqueueing an Oban job. See test/magus/agents/integration_test.exs
  # for tests of the new agent-based response flow.

  describe "Message response (Jido agent)" do
    test "send_user_message triggers agent signal instead of Oban job" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Send a user message - this triggers SignalAgent, not Oban
      {:ok, user_message} =
        Chat.send_user_message(
          %{text: "Hello, how are you?", conversation_id: conversation.id},
          actor: user
        )

      # The message should be created successfully
      assert user_message.role == :user
      assert user_message.text == "Hello, how are you?"

      # No Oban job should be enqueued for chat responses
      # (the Jido agent handles responses now)
      refute_enqueued(worker: Magus.Chat.Message.Workers.Respond)
    end
  end

  describe "Conversation generate_name trigger" do
    test "generate_name action runs synchronously (not via Oban)" do
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("Elixir Programming Discussion")
      end)

      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _} =
        Chat.send_user_message(
          %{text: "Tell me about Elixir programming", conversation_id: conversation.id},
          actor: user
        )

      # The generate_name action runs synchronously and calls the LLM
      {:ok, updated} =
        Ash.Changeset.for_update(conversation, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Elixir Programming Discussion"
    end
  end

  describe "File processing trigger" do
    test "create action enqueues processing job" do
      user = generate(user())
      setup_subscription_for_user(user)
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create a file - this should trigger processing
      {:ok, _file} =
        Files.create_file(
          %{
            name: "test.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "test/path/file.pdf",
            conversation_id: conversation.id
          },
          actor: user
        )

      # Verify processing job was enqueued
      assert_enqueued(
        worker: Magus.Files.File.Workers.ProcessFile,
        queue: :file_processing
      )
    end

    test "create_image action with agent source skips processing" do
      user = generate(user())

      # Create an image file via create_image (agent-generated)
      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "test.png", user_id: user.id},
          actor: @ai_agent
        )

      # Agent-generated images are marked as ready, not pending
      assert file.status == :ready
    end
  end

  # Note: The chat_responses queue is no longer used for message responses.
  # Jido agents handle responses synchronously/asynchronously without Oban.

  # Helper to set up a subscription with adequate limits for file uploads
  defp setup_subscription_for_user(user) do
    alias Magus.Usage

    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "test-plan-#{System.unique_integer([:positive])}",
          name: "Test Plan",
          storage_bytes: 1_000_000_000,
          max_upload_bytes: 100_000_000
        },
        authorize?: false
      )

    {:ok, _subscription} =
      Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )
  end
end
