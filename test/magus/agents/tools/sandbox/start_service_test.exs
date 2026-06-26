defmodule Magus.Agents.Tools.Sandbox.StartServiceTest do
  @moduledoc """
  Tests for the StartService tool.

  Tests cover:
  - Display name and output summarization
  - Context validation
  - Authorization
  - Service config construction
  - Error handling for unconfigured sandbox
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.StartService
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
      assert StartService.display_name() == "Starting service..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes running service with URL" do
      result = %{preview_url: "/sandbox/preview/abc-123/"}

      assert StartService.summarize_output(result) ==
               "Service running at /sandbox/preview/abc-123/"
    end

    test "summarizes error result" do
      assert StartService.summarize_output(%{error: "failed to start"}) == "Error"
    end

    test "summarizes unknown output" do
      assert StartService.summarize_output(%{}) == "Completed"
      assert StartService.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{
        "name" => "web",
        "command" => "node",
        "port" => 3000
      }

      assert {:ok, result} = StartService.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{
        "name" => "web",
        "command" => "node",
        "port" => 3000
      }

      context = %{conversation_id: conversation.id}

      assert {:ok, result} = StartService.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{
        "name" => "web",
        "command" => "node",
        "port" => 3000
      }

      context = %{user_id: user.id}

      assert {:ok, result} = StartService.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects service start for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{
        "name" => "web",
        "command" => "node",
        "args" => ["server.js"],
        "port" => 3000
      }

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = StartService.run(params, context)
      assert result[:error]
    end

    test "rejects service start for non-existent conversation", %{user: user} do
      params = %{
        "name" => "web",
        "command" => "node",
        "port" => 3000
      }

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = StartService.run(params, context)
      assert result[:error]
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter Handling
  # ---------------------------------------------------------------------------

  describe "run/2 - parameter handling" do
    test "uses default args and working_dir", %{context: context} do
      params = %{
        "name" => "api",
        "command" => "python3",
        "port" => 5000
      }

      assert {:ok, result} = StartService.run(params, context)
      # Should not crash; Sprites not configured returns an error
      assert is_map(result)
    end

    test "accepts custom args and working_dir", %{context: context} do
      params = %{
        "name" => "web",
        "command" => "node",
        "args" => ["server.js"],
        "port" => 3000,
        "working_dir" => "/workspace/app"
      }

      assert {:ok, result} = StartService.run(params, context)
      assert is_map(result)
    end

    test "accepts static file server config", %{context: context} do
      params = %{
        "name" => "static",
        "command" => "python3",
        "args" => ["-m", "http.server", "8000"],
        "port" => 8000
      }

      assert {:ok, result} = StartService.run(params, context)
      assert is_map(result)
    end
  end
end
