defmodule Magus.LiveE2E.SandboxTest do
  @moduledoc """
  Tests for code sandbox tools — direct tool calls and one agent integration test.

  Probes sandbox availability in setup; tests skip gracefully when not configured.
  Sandbox resources are cleaned up in on_exit.
  """
  use Magus.LiveE2ECase, async: false

  alias Magus.Agents.Tools.Sandbox.{RunCode, FileWrite, FileRead, FileDownload}

  @moduletag :sandbox
  @moduletag timeout: 240_000

  setup %{user: user, model: model} do
    conversation = create_conversation(user, model)
    context = %{conversation_id: conversation.id, user_id: user.id}

    # Probe sandbox availability with a trivial code execution
    {:ok, probe} = RunCode.run(%{"code" => "print('probe')"}, context)
    sandbox? = probe[:success] == true

    unless sandbox? do
      IO.puts("\n    [sandbox not configured — sandbox tests will be skipped]")
    end

    on_exit(fn ->
      case Magus.Sandbox.get_sandbox_by_conversation(conversation.id, authorize?: false) do
        {:ok, sandbox} -> Magus.Sandbox.terminate(sandbox, authorize?: false)
        _ -> :ok
      end
    end)

    %{conversation: conversation, context: context, sandbox?: sandbox?}
  end

  # ── Direct tool: code execution ──────────────────────────────────────

  describe "code execution (direct)" do
    test "runs Python and returns stdout", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, result} = RunCode.run(%{"code" => "print('Hello from sandbox!')"}, ctx)

        assert result[:success] == true
        assert result[:stdout] =~ "Hello from sandbox!"
        assert result[:exit_code] == 0
      end
    end

    test "runs a calculation", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, result} = RunCode.run(%{"code" => "print(sum(range(1, 101)))"}, ctx)

        assert result[:success] == true
        assert result[:stdout] =~ "5050"
      end
    end

    test "reports error for invalid code", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, result} = RunCode.run(%{"code" => "raise ValueError('boom')"}, ctx)

        assert result[:success] == false
        assert result[:stderr] =~ "ValueError"
      end
    end
  end

  # ── Direct tool: file operations ─────────────────────────────────────

  describe "file operations (direct)" do
    test "write and read a file", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, write_result} =
          FileWrite.run(%{"path" => "/workspace/e2e_test.txt", "content" => "Hello E2E"}, ctx)

        assert write_result[:path] =~ "e2e_test.txt"

        {:ok, read_result} = FileRead.run(%{"path" => "/workspace/e2e_test.txt"}, ctx)

        assert read_result[:content] =~ "Hello E2E"
      end
    end

    test "download a file", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, _} =
          FileWrite.run(
            %{"path" => "/workspace/download_test.csv", "content" => "name,age\nAlice,30"},
            ctx
          )

        {:ok, dl_result} =
          FileDownload.run(%{"path" => "/workspace/download_test.csv"}, ctx)

        assert dl_result[:filename] =~ "download_test"
        assert dl_result[:size_bytes] > 0
      end
    end

    test "read non-existent file returns error", %{context: ctx, sandbox?: sandbox?} do
      if sandbox? do
        {:ok, result} = FileRead.run(%{"path" => "/workspace/does_not_exist.txt"}, ctx)

        assert result[:error]
      end
    end
  end

  # ── Agent integration: coding skill + run_code via LLM ───────────────

  describe "agent integration" do
    @tag timeout: 300_000
    test "LLM loads coding skill and runs code in a single turn", %{
      user: user,
      conversation: conversation,
      sandbox?: sandbox?
    } do
      if sandbox? do
        subscribe_to_agent(conversation.id)

        # Single turn: load_skill registers run_code mid-turn, LLM uses it immediately
        send_user_message(
          conversation,
          user,
          "First load the 'coding' skill, then use run_code to execute: print(2 ** 10). Tell me the result."
        )

        assert_tool_started("load_skill", 120_000)
        assert_tool_completed("load_skill", 120_000)
        assert_tool_started("run_code", 120_000)
        assert_tool_completed("run_code", 120_000)
        assert_response_complete(120_000)

        message = latest_agent_message(conversation.id)
        assert message, "Expected agent message to be persisted"
        assert message.text =~ "1024", "Expected 1024 in response, got: #{message.text}"
      end
    end
  end
end
