defmodule Magus.Agents.Tools.Sandbox.RunCode do
  @moduledoc """
  Jido tool for executing Python code in a persistent sandbox environment.

  The sandbox maintains state between executions—installed packages, variables,
  and files persist across messages within a conversation.
  """

  use Jido.Action,
    name: "run_code",
    description: """
    Execute Python code in a persistent sandbox environment. The sandbox maintains state
    between executions—installed packages, variables, and files persist across messages.

    Use this for:
    - Mathematical calculations
    - Data analysis with pandas, numpy, etc.
    - Generating CSV, JSON, Excel, or PDF files
    - Creating charts and visualizations
    - Processing uploaded files
    - Any computation that benefits from real Python code execution

    Working directory: /workspace

    IMPORTANT: Only Python's standard library is available by default. Use the install_packages
    tool first if you need external libraries like numpy, pandas, matplotlib, etc.

    DO NOT use this tool to run shell commands. Never use os.system(), subprocess, os.popen(),
    or similar — use the exec_command tool instead for shell commands.

    Response includes `workspace_files` — a list of all files in the workspace. Use `sandbox_read_file` to load
    file contents into your context if needed.

    IMPORTANT: Interpret results for the user in natural language. Don't dump raw output—explain what it means.
    """,
    schema: [
      code: [
        type: :string,
        required: true,
        doc: "Python code to execute"
      ],
      description: [
        type: :string,
        required: false,
        doc: "Brief description of what this code does (for logging)"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Helpers
  alias Magus.Sandbox.Orchestrator

  @timeout_ms 120_000

  @doc "User-friendly display name shown in the UI"
  def display_name, do: "Running code..."

  @doc "Generate a human-readable summary of output"
  def summarize_output(%{success: true, workspace_files: files})
      when is_list(files) and length(files) > 0 do
    "#{length(files)} file(s) in workspace"
  end

  def summarize_output(%{success: true}), do: "Executed successfully"

  def summarize_output(%{success: false, error_type: type}) when is_binary(type),
    do: "Failed: #{type}"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(%{"code" => code} = params, context) when is_binary(code) and code != "" do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        execute_code(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  def run(_params, _context) do
    {:ok,
     %{
       error: "The 'code' parameter must be a non-empty string containing Python code to execute."
     }}
  end

  defp execute_code(conversation_id, user_id, params, context) do
    # Step 0: Setup
    Signals.emit_tool_step_start(context, 0, "Setting up workspace")

    base_opts = [
      timeout_ms: @timeout_ms,
      description: params["description"],
      message_id: params["message_id"],
      user_id: user_id
    ]

    opts =
      case build_streaming_callback(context) do
        nil -> base_opts
        callback -> Keyword.put(base_opts, :on_output, callback)
      end

    Signals.emit_tool_step_complete(context, 0)

    # Step 1: Execute
    Signals.emit_tool_step_start(context, 1, "Running Python code")

    case Orchestrator.execute(conversation_id, params["code"], opts) do
      {:ok, result} ->
        workspace_files = Map.get(result, :workspace_files, [])

        summary = if result.exit_code == 0, do: "exit 0", else: "exit #{result.exit_code}"
        Signals.emit_tool_step_complete(context, 1, :complete, summary)

        # Step 2: Files (only if files exist)
        if is_list(workspace_files) and length(workspace_files) > 0 do
          Signals.emit_tool_step_start(
            context,
            2,
            "#{length(workspace_files)} file(s) in workspace"
          )

          Signals.emit_tool_step_complete(context, 2)
        end

        {:ok, format_success(result)}

      {:error, :forbidden_code, message} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Rejected")
        {:ok, format_validation_error(message)}

      {:error, :code_too_long, message} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Code too long")
        {:ok, format_validation_error(message)}

      {:error, :timeout, partial} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Timed out")
        {:ok, format_timeout(partial)}

      {:error, :oom, partial} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Out of memory")
        {:ok, format_oom(partial)}

      {:error, :not_configured, _} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Not configured")

        {:ok,
         %{
           success: false,
           error_type: "configuration_error",
           error: "Code execution is not configured. Please contact support.",
           hint: "The sandbox service is not available."
         }}

      {:error, :sprite_not_found, _} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Sandbox unavailable")

        {:ok,
         %{
           success: false,
           error_type: "sandbox_unavailable",
           error: "The sandbox is temporarily unavailable. Please try again.",
           hint: "The sandbox session may have expired. A new one will be created on retry."
         }}

      {:error, _type, details} ->
        Signals.emit_tool_step_complete(context, 1, :error, "Failed")
        {:ok, format_error(details)}
    end
  end

  defp format_success(result) do
    workspace_files = Map.get(result, :workspace_files, [])

    base = %{
      success: result.exit_code == 0,
      stdout: result.stdout,
      stderr: result.stderr,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      workspace_files: format_workspace_files(workspace_files),
      execution_id: Map.get(result, :execution_id),
      hint:
        "Interpret results for the user. Files are shown to the user with download buttons automatically. Use sandbox_read_file to load file contents if you need to analyze them."
    }

    if result.exit_code != 0 and
         is_binary(result.stderr) and
         String.contains?(result.stderr, "ModuleNotFoundError") do
      Map.put(
        base,
        :import_error_hint,
        "A required package is not installed. Use install_packages to install it, then retry."
      )
    else
      base
    end
  end

  defp format_workspace_files(files) when is_list(files) do
    Enum.map(files, fn file ->
      %{name: file.name, path: file.path, size: file.size}
    end)
  end

  defp format_workspace_files(_), do: []

  defp format_validation_error(message) do
    %{
      success: false,
      error_type: "validation_error",
      error: message,
      hint:
        "The code was rejected before execution. Modify the code to avoid the restricted pattern."
    }
  end

  defp format_timeout(partial) when is_map(partial) do
    %{
      success: false,
      stdout: Map.get(partial, :stdout, "") || "",
      stderr: "Execution timed out after the maximum allowed time.",
      error_type: "timeout",
      hint:
        "The code took too long. Consider optimizing the algorithm, processing less data, or breaking the task into smaller steps."
    }
  end

  defp format_timeout(_), do: format_timeout(%{})

  defp format_oom(partial) when is_map(partial) do
    %{
      success: false,
      stdout: Map.get(partial, :stdout, "") || "",
      stderr: "Out of memory. The code used more than 512MB of RAM.",
      error_type: "oom",
      hint:
        "Try processing smaller datasets, using more memory-efficient data structures, or streaming data instead of loading it all at once."
    }
  end

  defp format_oom(_), do: format_oom(%{})

  # Handle Ash errors and other structs (structs are maps but don't implement Access)
  defp format_error(%{__struct__: _} = error) do
    message =
      case error do
        %{message: msg} when is_binary(msg) -> msg
        _ -> Exception.message(error)
      end

    %{
      success: false,
      stdout: "",
      stderr: message,
      error_type: "internal_error",
      hint: "An internal error occurred. Please try again or contact support."
    }
  end

  # Handle plain maps with stdout/stderr keys
  defp format_error(details) when is_map(details) do
    %{
      success: false,
      stdout: Map.get(details, :stdout, "") || "",
      stderr: Map.get(details, :stderr, "") || inspect(details),
      error_type: "runtime_error",
      hint: "There's an error in the code. Review the stderr output, fix the issue, and retry."
    }
  end

  defp format_error(details) do
    %{
      success: false,
      stdout: "",
      stderr: inspect(details),
      error_type: "unknown_error",
      hint: "An unexpected error occurred. Try again or simplify the code."
    }
  end

  defp build_streaming_callback(context) do
    Helpers.build_step_streaming_callback(context, 1)
  end
end
