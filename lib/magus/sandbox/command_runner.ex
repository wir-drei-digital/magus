defmodule Magus.Sandbox.CommandRunner do
  @moduledoc """
  Executes arbitrary shell commands in a sandbox.

  Unlike `CodeRunner` which is Python-specific (writes script.py, detects output files),
  this module runs any shell command directly via the sandbox provider's exec.
  """

  alias Magus.Sandbox.Provider

  require Logger

  @default_timeout 30_000

  @doc """
  Run a shell command in the sandbox.

  ## Options

    * `:timeout_ms` - Maximum execution time in milliseconds (default: 30_000). No upper cap — the caller decides how long to wait.
    * `:working_dir` - Working directory (default: "/workspace")

  ## Returns

    * `{:ok, result}` - Command completed with stdout, stderr, exit_code, duration_ms
    * `{:error, :timeout, partial}` - Command timed out
    * `{:error, :oom, partial}` - Out of memory
    * `{:error, :execution_failed, reason}` - Other error
  """
  @spec run(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom(), map() | term()}
  def run(sandbox, command, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout)
    working_dir = Keyword.get(opts, :working_dir, "/workspace")
    client = Provider.client_for(sandbox)

    full_command = "cd #{escape_shell_arg(working_dir)} && #{command}"

    exec_opts = [timeout: timeout_ms]

    exec_opts =
      if on_output = Keyword.get(opts, :on_output),
        do: Keyword.put(exec_opts, :on_output, on_output),
        else: exec_opts

    case client.exec(sandbox.sprite_id, full_command, exec_opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :timeout} ->
        {:error, :timeout, %{stdout: "", stderr: "Command timed out"}}

      {:error, :oom} ->
        {:error, :oom, %{stdout: "", stderr: "Out of memory"}}

      {:error, :not_configured} ->
        {:error, :not_configured, %{stdout: "", stderr: "Sandbox not configured"}}

      {:error, reason} ->
        {:error, :execution_failed, reason}
    end
  end

  # Shell-escape a single argument using single quotes.
  # Single quotes prevent all shell interpretation; embedded single quotes
  # are escaped by ending the quote, adding an escaped quote, and reopening.
  defp escape_shell_arg(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end
end
