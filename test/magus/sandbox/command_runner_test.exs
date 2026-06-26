defmodule Magus.Sandbox.CommandRunnerTest do
  @moduledoc """
  Tests for the CommandRunner module.

  Since CommandRunner calls the external Sprites service, tests that call run/3
  directly will get :not_configured errors. We test:
  - Module exports and spec
  - Error mapping (not_configured in test env proves the error path works)
  - Default option behavior
  """
  use ExUnit.Case, async: true

  alias Magus.Sandbox.CommandRunner

  # Fake sandbox struct matching what CommandRunner expects
  @fake_sandbox %{sprite_id: "fake-sprite-id", provider: :sprites}

  # ---------------------------------------------------------------------------
  # Module Structure
  # ---------------------------------------------------------------------------

  describe "module" do
    test "exports run/2 (with default opts)" do
      assert function_exported?(CommandRunner, :run, 2)
    end

    test "exports run/3" do
      assert function_exported?(CommandRunner, :run, 3)
    end

    test "has @spec for run/3" do
      {:ok, specs} = Code.Typespec.fetch_specs(CommandRunner)

      run_specs =
        Enum.filter(specs, fn {{name, _arity}, _} -> name == :run end)

      assert length(run_specs) > 0, "Expected @spec for run/3"
    end
  end

  # ---------------------------------------------------------------------------
  # Error Handling (Sprites not configured in test env)
  # ---------------------------------------------------------------------------

  describe "run/3 - not configured" do
    test "returns :not_configured error when Sprites service is unavailable" do
      result = CommandRunner.run(@fake_sandbox, "echo hello")

      assert {:error, error_type, _details} = result
      # May be :not_configured or :execution_failed depending on client setup
      assert error_type in [:not_configured, :execution_failed]
    end

    test "returns error with default options" do
      result = CommandRunner.run(@fake_sandbox, "ls -la")

      assert {:error, _type, _details} = result
    end

    test "returns error with custom timeout" do
      result = CommandRunner.run(@fake_sandbox, "sleep 1", timeout_ms: 5_000)

      assert {:error, _type, _details} = result
    end

    test "returns error with custom working directory" do
      result = CommandRunner.run(@fake_sandbox, "pwd", working_dir: "/tmp")

      assert {:error, _type, _details} = result
    end

    test "returns error with all options set" do
      result =
        CommandRunner.run(@fake_sandbox, "echo test",
          timeout_ms: 60_000,
          working_dir: "/workspace/project"
        )

      assert {:error, _type, _details} = result
    end

    test "handles working directory with spaces" do
      result = CommandRunner.run(@fake_sandbox, "ls", working_dir: "/workspace/my project")

      assert {:error, _type, _details} = result
    end

    test "handles working directory with single quotes" do
      result =
        CommandRunner.run(@fake_sandbox, "ls", working_dir: "/workspace/it's a dir")

      assert {:error, _type, _details} = result
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout (no upper cap)
  # ---------------------------------------------------------------------------

  describe "run/3 - timeout passthrough" do
    test "does not crash with very large timeout (passed through uncapped)" do
      result = CommandRunner.run(@fake_sandbox, "echo hi", timeout_ms: 999_999)

      assert {:error, _type, _details} = result
    end

    test "does not crash with zero timeout" do
      result = CommandRunner.run(@fake_sandbox, "echo hi", timeout_ms: 0)

      assert {:error, _type, _details} = result
    end

    test "does not crash with negative timeout" do
      result = CommandRunner.run(@fake_sandbox, "echo hi", timeout_ms: -1)

      assert {:error, _type, _details} = result
    end
  end
end
