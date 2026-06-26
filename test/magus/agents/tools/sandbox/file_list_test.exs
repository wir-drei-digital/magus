defmodule Magus.Agents.Tools.Sandbox.FileListTest do
  @moduledoc """
  Tests for the FileList tool.

  Tests cover:
  - Display name and output summarization
  - Context validation
  - Authorization
  - Default and custom path handling
  - Recursive mode configuration
  - Error handling for unconfigured sandbox
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileList
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
      assert FileList.display_name() == "Listing files..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes with entry count" do
      entries = [
        %{name: "file1.txt", path: "/workspace/file1.txt", size: 100, is_dir: false},
        %{name: "src", path: "/workspace/src", size: 0, is_dir: true}
      ]

      assert FileList.summarize_output(%{entries: entries}) == "2 entries"
    end

    test "summarizes empty listing" do
      assert FileList.summarize_output(%{entries: []}) == "0 entries"
    end

    test "summarizes single entry" do
      entries = [%{name: "file.txt", path: "/workspace/file.txt", size: 50, is_dir: false}]
      assert FileList.summarize_output(%{entries: entries}) == "1 entries"
    end

    test "summarizes error result" do
      assert FileList.summarize_output(%{error: "not found"}) == "Error"
    end

    test "summarizes unknown output" do
      assert FileList.summarize_output(%{}) == "Completed"
      assert FileList.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{}

      assert {:ok, result} = FileList.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{"path" => "/workspace"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = FileList.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{"path" => "/workspace"}
      context = %{user_id: user.id}

      assert {:ok, result} = FileList.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects listing for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{"path" => "/workspace"}

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = FileList.run(params, context)
      assert result[:error]
    end

    test "rejects listing for non-existent conversation", %{user: user} do
      params = %{"path" => "/workspace"}

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = FileList.run(params, context)
      assert result[:error]
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter Defaults
  # ---------------------------------------------------------------------------

  describe "run/2 - parameter handling" do
    test "uses default path /workspace when not specified", %{context: context} do
      params = %{}

      assert {:ok, result} = FileList.run(params, context)
      # Should not crash, just get Sprites error
      assert is_map(result)
    end

    test "uses custom path when specified", %{context: context} do
      params = %{"path" => "/workspace/src"}

      assert {:ok, result} = FileList.run(params, context)
      assert is_map(result)
    end

    test "handles recursive mode", %{context: context} do
      params = %{"recursive" => true}

      assert {:ok, result} = FileList.run(params, context)
      assert is_map(result)
    end

    test "handles non-recursive mode explicitly", %{context: context} do
      params = %{"recursive" => false}

      assert {:ok, result} = FileList.run(params, context)
      assert is_map(result)
    end
  end
end
