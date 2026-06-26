defmodule Magus.Agents.Tools.Sandbox.ExecCommandOutputTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Sandbox.ExecCommand

  describe "interpret_exit_code/2" do
    test "returns nil for exit code 0" do
      assert ExecCommand.interpret_exit_code("ls", 0) == nil
    end

    test "interprets grep exit 1 as no matches" do
      assert ExecCommand.interpret_exit_code("grep pattern file", 1) =~ "No matches"
    end

    test "interprets rg exit 1 as no matches" do
      assert ExecCommand.interpret_exit_code("rg pattern", 1) =~ "No matches"
    end

    test "interprets diff exit 1 as files differ" do
      assert ExecCommand.interpret_exit_code("diff a b", 1) =~ "differ"
    end

    test "interprets exit 127 as command not found" do
      assert ExecCommand.interpret_exit_code("nonexistent", 127) =~ "not found"
    end

    test "interprets exit 137 as killed" do
      assert ExecCommand.interpret_exit_code("heavy_process", 137) =~ "Killed"
    end

    test "interprets exit 139 as segfault" do
      assert ExecCommand.interpret_exit_code("crash", 139) =~ "Segmentation"
    end

    test "returns nil for unknown non-zero exit code" do
      assert ExecCommand.interpret_exit_code("some_cmd", 42) == nil
    end

    test "handles empty command string" do
      assert ExecCommand.interpret_exit_code("", 1) == nil
    end

    test "handles command with path prefix" do
      assert ExecCommand.interpret_exit_code("/usr/bin/grep foo", 1) =~ "No matches"
    end
  end
end
