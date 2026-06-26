defmodule Magus.Sandbox.CodeRunner do
  @moduledoc """
  Handles the actual execution of code in a sandbox.

  Responsible for:
  - Writing code to the sandbox filesystem
  - Executing code via the sandbox provider
  - Listing workspace files after execution
  - Emitting telemetry events

  ## Workspace Structure

  - `/workspace/script.py` - The script file written before execution
  - `/workspace/` - Working directory where code runs and files are created

  After execution, all files in /workspace are listed and returned.
  """

  alias Magus.Sandbox
  alias Magus.Sandbox.Provider
  alias Magus.Sandbox.WorkspaceManager

  require Logger

  # Workspace paths
  @workspace_dir WorkspaceManager.workspace_dir()
  @script_path "#{@workspace_dir}/script.py"

  @doc """
  Execute code in the sandbox and return parsed results.

  1. Writes code to script file via filesystem API
  2. Executes the script via command API
  3. Lists workspace files after execution

  Emits telemetry events for execution start/stop.

  ## Returns

    * `{:ok, result}` - Execution succeeded with parsed output
    * `{:error, :timeout, partial}` - Execution timed out
    * `{:error, :oom, partial}` - Out of memory
    * `{:error, :not_configured, partial}` - Sandbox not configured
    * `{:error, :execution_failed, reason}` - Other execution error
  """
  def run(sandbox, execution, code, opts) do
    timeout = min(Keyword.get(opts, :timeout_ms, 30_000), 600_000)
    client = Provider.client_for(sandbox)
    start_time = System.monotonic_time()

    # Emit telemetry for execution start
    :telemetry.execute(
      [:magus, :sandbox, :execution, :start],
      %{system_time: System.system_time()},
      %{
        sandbox_id: sandbox.id,
        execution_id: execution.id,
        conversation_id: sandbox.conversation_id,
        code_length: byte_size(code)
      }
    )

    # Mark execution as running
    Sandbox.start_execution(execution, authorize?: false)

    # Write the script file to the sandbox
    script_content = build_script(code)

    on_output = Keyword.get(opts, :on_output)

    result =
      case client.write_file(sandbox.sprite_id, @script_path, script_content) do
        :ok ->
          execute_script(client, sandbox, timeout, on_output)

        {:error, {:api_error, 404, _}} ->
          Logger.error("Sandbox #{sandbox.sprite_id} not found when writing script")

          {:error, :sprite_not_found,
           %{stdout: "", stderr: "Sandbox not available. Please try again."}}

        {:error, :not_configured} ->
          {:error, :not_configured, %{stdout: "", stderr: "Sandbox not configured"}}

        {:error, reason} ->
          Logger.error("Failed to write script file: #{inspect(reason)}")
          {:error, :execution_failed, {:write_error, reason}}
      end

    duration = System.monotonic_time() - start_time

    # Emit telemetry for execution completion
    :telemetry.execute(
      [:magus, :sandbox, :execution, :stop],
      %{duration: duration},
      %{
        sandbox_id: sandbox.id,
        execution_id: execution.id,
        conversation_id: sandbox.conversation_id,
        success: match?({:ok, _}, result),
        error_type: error_type_from_result(result)
      }
    )

    result
  end

  defp error_type_from_result({:ok, _}), do: nil
  defp error_type_from_result({:error, type, _}), do: type

  # Build the script content - runs in /workspace (cwd set by CommandRunner)
  defp build_script(code), do: code

  # Execute the script and list workspace files afterward
  defp execute_script(client, sandbox, timeout, on_output) do
    command = "python3 #{@script_path}"

    exec_opts = [timeout: timeout]

    exec_opts =
      if on_output,
        do: Keyword.put(exec_opts, :on_output, on_output),
        else: exec_opts

    case client.exec(sandbox.sprite_id, command, exec_opts) do
      {:ok, exec_result} ->
        # List all workspace files after execution
        workspace_files = list_workspace_files(sandbox)
        {:ok, build_result(exec_result, workspace_files)}

      {:error, :timeout} ->
        {:error, :timeout, %{stdout: "", stderr: "Execution timed out"}}

      {:error, :oom} ->
        {:error, :oom, %{stdout: "", stderr: "Out of memory"}}

      {:error, :not_configured} ->
        {:error, :not_configured, %{stdout: "", stderr: "Sandbox not configured"}}

      {:error, reason} ->
        {:error, :execution_failed, reason}
    end
  end

  # List workspace files using WorkspaceManager
  defp list_workspace_files(sandbox) do
    case WorkspaceManager.list_workspace_files(sandbox) do
      {:ok, files} -> files
      {:error, _} -> []
    end
  end

  # Build the result map
  defp build_result(exec_result, workspace_files) do
    %{
      stdout: exec_result.stdout || "",
      stderr: exec_result.stderr || "",
      exit_code: exec_result.exit_code || 0,
      duration_ms: exec_result.duration_ms || 0,
      workspace_files: workspace_files
    }
  end
end
