defmodule Magus.Agents.Tools.Sandbox.FileDownloadTest do
  @moduledoc """
  Tests for the FileDownload tool.

  Tests cover:
  - Display name and output summarization
  - Context validation
  - Authorization
  - Sandbox not configured handling
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileDownload
  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    context = %{
      user_id: user.id,
      conversation_id: conversation.id
    }

    %{user: user, conversation: conversation, context: context}
  end

  # ---------------------------------------------------------------------------
  # Display Name and Output Summarization
  # ---------------------------------------------------------------------------

  describe "display_name/0" do
    test "provides display name" do
      assert FileDownload.display_name() == "Preparing download..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful download with filename and size" do
      assert FileDownload.summarize_output(%{filename: "document.pdf", size_bytes: 1024}) ==
               "document.pdf (1.0 KB)"
    end

    test "summarizes with bytes" do
      assert FileDownload.summarize_output(%{filename: "small.txt", size_bytes: 500}) ==
               "small.txt (500 B)"
    end

    test "summarizes with megabytes" do
      assert FileDownload.summarize_output(%{filename: "large.zip", size_bytes: 2_621_440}) ==
               "large.zip (2.5 MB)"
    end

    test "summarizes with nil size" do
      assert FileDownload.summarize_output(%{filename: "file.pdf", size_bytes: nil}) ==
               "file.pdf (unknown)"
    end

    test "summarizes error result" do
      assert FileDownload.summarize_output(%{error: "not found"}) == "Error"
    end

    test "summarizes unknown output" do
      assert FileDownload.summarize_output(%{}) == "Completed"
      assert FileDownload.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"path" => "/workspace/document.pdf"}

      assert {:ok, result} = FileDownload.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{"path" => "/workspace/document.pdf"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = FileDownload.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{"path" => "/workspace/document.pdf"}
      context = %{user_id: user.id}

      assert {:ok, result} = FileDownload.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects download for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{"path" => "/workspace/document.pdf"}

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = FileDownload.run(params, context)
      assert result[:error]
    end

    test "rejects download for non-existent conversation", %{user: user} do
      params = %{"path" => "/workspace/document.pdf"}

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = FileDownload.run(params, context)
      assert result[:error]
    end
  end
end
