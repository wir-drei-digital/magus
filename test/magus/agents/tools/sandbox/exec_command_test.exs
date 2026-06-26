defmodule Magus.Agents.Tools.Sandbox.ExecCommandTest do
  @moduledoc """
  Tests for the ExecCommand tool.

  Tests cover:
  - Display name and output summarization
  - Context validation (missing user_id, conversation_id)
  - Authorization (non-owner, non-existent conversation)
  - Timeout calculation
  - Error formatting for various error types
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Sandbox.ExecCommand
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
      assert ExecCommand.display_name() == "Executing command..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes successful command with exit code 0" do
      assert ExecCommand.summarize_output(%{success: true, exit_code: 0}) ==
               "Command succeeded"
    end

    test "summarizes successful command with non-zero exit code" do
      assert ExecCommand.summarize_output(%{success: true, exit_code: 1}) ==
               "Exited with code 1"
    end

    test "summarizes successful command with exit code 127" do
      assert ExecCommand.summarize_output(%{success: true, exit_code: 127}) ==
               "Exited with code 127"
    end

    test "summarizes failed command with error type" do
      assert ExecCommand.summarize_output(%{success: false, error_type: "timeout"}) ==
               "Failed: timeout"
    end

    test "summarizes failed command with oom error type" do
      assert ExecCommand.summarize_output(%{success: false, error_type: "oom"}) ==
               "Failed: oom"
    end

    test "summarizes error result" do
      assert ExecCommand.summarize_output(%{error: "some error"}) == "Error"
    end

    test "summarizes unknown output" do
      assert ExecCommand.summarize_output(%{}) == "Completed"
      assert ExecCommand.summarize_output(%{foo: "bar"}) == "Completed"
    end
  end

  # ---------------------------------------------------------------------------
  # Context Validation
  # ---------------------------------------------------------------------------

  describe "run/2 - context validation" do
    test "returns error with empty context" do
      params = %{"command" => "ls"}

      assert {:ok, result} = ExecCommand.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing user_id", %{conversation: conversation} do
      params = %{"command" => "ls"}
      context = %{conversation_id: conversation.id}

      assert {:ok, result} = ExecCommand.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "user_id"
    end

    test "returns error with missing conversation_id", %{user: user} do
      params = %{"command" => "ls"}
      context = %{user_id: user.id}

      assert {:ok, result} = ExecCommand.run(params, context)
      assert result.error =~ "Missing required context"
      assert result.error =~ "conversation_id"
    end

    test "works with string keys in context", %{user: user, conversation: conversation} do
      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      params = %{"command" => "echo hello"}

      # Will fail at Sprites level (not configured) but should pass context validation
      assert {:ok, result} = ExecCommand.run(params, string_context)
      # Should not be a context validation error
      refute is_binary(result[:error]) and result[:error] =~ "Missing required context"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "run/2 - authorization" do
    test "rejects command for non-owner user", %{conversation: conversation} do
      other_user = generate(user())

      params = %{"command" => "ls"}

      context = %{
        user_id: other_user.id,
        conversation_id: conversation.id
      }

      assert {:ok, result} = ExecCommand.run(params, context)
      # Should get an error (not_found due to Ash policy filtering)
      assert result[:error] || result[:success] == false
    end

    test "rejects command for non-existent conversation", %{user: user} do
      params = %{"command" => "ls"}

      context = %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      }

      assert {:ok, result} = ExecCommand.run(params, context)
      assert result[:error] || result[:success] == false
    end
  end

  # ---------------------------------------------------------------------------
  # Sandbox Not Configured (expected in test environment)
  # ---------------------------------------------------------------------------

  describe "run/2 - sandbox not configured" do
    test "uses default working directory", %{context: context} do
      params = %{"command" => "pwd"}

      assert {:ok, result} = ExecCommand.run(params, context)
      # Should not crash - just return an error from unconfigured Sprites
      assert is_map(result)
    end

    test "uses custom working directory", %{context: context} do
      params = %{"command" => "pwd", "working_dir" => "/tmp"}

      assert {:ok, result} = ExecCommand.run(params, context)
      assert is_map(result)
    end

    test "uses default timeout when not specified", %{context: context} do
      params = %{"command" => "sleep 1"}

      assert {:ok, result} = ExecCommand.run(params, context)
      assert is_map(result)
    end

    test "uses custom timeout", %{context: context} do
      params = %{"command" => "sleep 1", "timeout" => 60}

      assert {:ok, result} = ExecCommand.run(params, context)
      assert is_map(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Output Streaming
  # ---------------------------------------------------------------------------

  describe "output streaming" do
    test "build_exec_opts includes on_output callback when context has event metadata" do
      context = %{
        user_id: "test-user",
        conversation_id: "test-conv",
        __conversation_id__: "test-conv",
        __event_id__: "test-event-id",
        __tool_name__: "exec_command"
      }

      opts = ExecCommand.build_exec_opts(context, %{"command" => "echo hi", "timeout" => 300})
      assert is_function(opts[:on_output], 1)
    end

    test "build_exec_opts omits on_output when event metadata is missing" do
      context = %{
        user_id: "test-user",
        conversation_id: "test-conv"
      }

      opts = ExecCommand.build_exec_opts(context, %{"command" => "echo hi", "timeout" => 300})
      refute Keyword.has_key?(opts, :on_output)
    end

    test "build_exec_opts omits on_output when only some metadata keys are present" do
      context = %{
        user_id: "test-user",
        conversation_id: "test-conv",
        __conversation_id__: "test-conv"
        # missing __event_id__ and __tool_name__
      }

      opts = ExecCommand.build_exec_opts(context, %{"command" => "echo hi"})
      refute Keyword.has_key?(opts, :on_output)
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout Parameter
  # ---------------------------------------------------------------------------

  describe "secret injection" do
    test "build_env_file_content/1 formats secrets as .env file with single-quoted values" do
      secrets = %{"GITHUB_TOKEN" => "ghp_123", "API_KEY" => "sk-abc"}
      content = ExecCommand.build_env_file_content(secrets)

      assert content =~ "export GITHUB_TOKEN='ghp_123'"
      assert content =~ "export API_KEY='sk-abc'"
    end

    test "build_env_file_content/1 escapes single quotes in values" do
      secrets = %{"PASS" => "it's a secret"}
      content = ExecCommand.build_env_file_content(secrets)

      assert content =~ "export PASS='it'\\''s a secret'"
    end

    test "build_env_file_content/1 returns empty string for empty map" do
      assert ExecCommand.build_env_file_content(%{}) == ""
    end
  end

  describe "timeout parameter" do
    test "accepts custom timeout in schema" do
      assert {:ok, _} =
               NimbleOptions.validate(
                 [command: "echo hi", timeout: 1800],
                 ExecCommand.schema()
               )
    end

    test "uses custom timeout in build_exec_opts" do
      context = %{user_id: "u", conversation_id: "c"}
      opts = ExecCommand.build_exec_opts(context, %{"command" => "hi", "timeout" => 1800})
      assert opts[:timeout_ms] == 1_800_000
    end

    test "uses default timeout of 300s when not specified" do
      context = %{user_id: "u", conversation_id: "c"}
      opts = ExecCommand.build_exec_opts(context, %{"command" => "hi"})
      assert opts[:timeout_ms] == 300_000
    end
  end
end
