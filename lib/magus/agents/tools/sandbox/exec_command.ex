defmodule Magus.Agents.Tools.Sandbox.ExecCommand do
  @moduledoc """
  Jido tool for executing shell commands in a persistent sandbox environment.

  The sandbox runs Ubuntu 24.04 with Python, Node.js, Go, Ruby, and Rust
  pre-installed. Commands persist state between executions within a conversation.
  """

  use Jido.Action,
    name: "exec_command",
    description: """
    Execute a shell command that completes quickly in a persistent sandbox (Ubuntu 24.04).

    Pre-installed runtimes: Python 3.12, Node.js, Go, Ruby, Rust.
    You can install additional packages with apt-get, npm, uv pip, cargo, gem, etc.

    Use this for:
    - Running any shell command (ls, cat, grep, curl, etc.)
    - Compiling code (gcc, rustc, go build, etc.)
    - Installing system packages (apt-get install)
    - Running scripts in any language
    - Building projects (make, npm run build, etc.)
    - LaTeX compilation (pdflatex, xelatex)

    NEVER use this for starting web servers or long-running services (e.g. python3 -m http.server,
    node server.js, flask run, etc.). Those commands never finish and will time out.
    Use start_service instead — it starts the process in the background and returns a preview URL.

    Working directory: /workspace (persists between calls)
    Network: restricted to package registries (PyPI, npm, crates.io, apt repos, GitHub).

    Response includes `workspace_files` — a list of all files in the workspace. Use `sandbox_read_file` to load
    file contents into your context if needed.

    IMPORTANT: Interpret results for the user in natural language. Don't dump raw output.
    """,
    schema: [
      command: [
        type: :string,
        required: true,
        doc: "Shell command to execute"
      ],
      working_dir: [
        type: :string,
        required: false,
        default: "/workspace",
        doc: "Working directory (default: /workspace)"
      ],
      timeout: [
        type: :integer,
        required: false,
        default: 300,
        doc:
          "Maximum execution time in seconds (default: 300). The agent decides how long to wait — there is no upper cap."
      ]
    ]

  # Max output size before truncation (30KB)
  @max_output_bytes 30_000
  @max_line_length 500
  @silent_commands ~w(mkdir touch mv cp rm rmdir chmod chown ln)

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Helpers
  alias Magus.Agents.Tools.Sandbox.SandboxHelpers
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Executing command..."

  def summarize_output(%{success: true, exit_code: 0}), do: "Command succeeded"

  def summarize_output(%{success: true, exit_code: code}) when is_integer(code),
    do: "Exited with code #{code}"

  def summarize_output(%{success: false, error_type: type}) when is_binary(type),
    do: "Failed: #{type}"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        execute_command(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  @doc false
  def build_env_file_content(env_map) when map_size(env_map) == 0, do: ""

  def build_env_file_content(env_map) do
    env_map
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.map(fn {key, value} ->
      escaped = String.replace(value, "'", "'\\''")
      "export #{key}='#{escaped}'"
    end)
    |> Enum.join("\n")
  end

  @doc false
  def build_exec_opts(context, params) do
    timeout_s = Map.get(params, "timeout", 300)
    working_dir = Map.get(params, "working_dir", "/workspace")
    command = Map.get(params, "command", "")

    base_opts = [
      timeout_ms: timeout_s * 1_000,
      working_dir: working_dir,
      description: command,
      user_id: Map.get(context, :user_id) || Map.get(context, "user_id")
    ]

    case build_streaming_callback(context) do
      nil -> base_opts
      callback -> Keyword.put(base_opts, :on_output, callback)
    end
  end

  defp build_streaming_callback(context) do
    Helpers.build_step_streaming_callback(context, 1)
  end

  defp maybe_inject_secrets(conversation_id, context) do
    ai_actor = Helpers.ai_actor()

    with {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, actor: ai_actor),
         custom_agent_id when not is_nil(custom_agent_id) <- conversation.custom_agent_id,
         {:ok, env_map} <-
           Magus.Agents.sandbox_env_map_for_agent(custom_agent_id, actor: ai_actor),
         true <- map_size(env_map) > 0 do
      env_content = build_env_file_content(env_map)

      Orchestrator.write_file(
        conversation_id,
        "/workspace/.env",
        env_content,
        user_id: context[:user_id]
      )
    else
      _ -> :ok
    end
  end

  defp execute_command(conversation_id, _user_id, params, context) do
    command = params["command"]

    # Step 0: Setup
    Signals.emit_tool_step_start(context, 0, "Setting up sandbox")
    maybe_inject_secrets(conversation_id, context)
    opts = build_exec_opts(context, params)
    Signals.emit_tool_step_complete(context, 0)

    # Step 1: Execute
    Signals.emit_tool_step_start(context, 1, "Running: #{truncate(command, 80)}")

    result =
      case Orchestrator.exec_command(conversation_id, command, opts) do
        {:ok, result} ->
          summary = if result.exit_code == 0, do: "exit 0", else: "exit #{result.exit_code}"
          Signals.emit_tool_step_complete(context, 1, :complete, summary)
          {:ok, format_success(Map.put(result, :command, command))}

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

    result
  end

  defp format_success(result) do
    workspace_files =
      result
      |> Map.get(:workspace_files, [])
      |> Enum.map(fn file -> %{name: file.name, path: file.path, size: file.size} end)

    stdout = (result.stdout || "") |> SandboxHelpers.cap_line_length(@max_line_length)
    stderr = (result.stderr || "") |> SandboxHelpers.cap_line_length(@max_line_length)

    {stdout, truncated} =
      case SandboxHelpers.truncate_output(stdout, @max_output_bytes) do
        {:ok, content} -> {content, false}
        {:truncated, content, _original_size} -> {content, true}
      end

    command = Map.get(result, :command, "")

    response = %{
      success: result.exit_code == 0,
      stdout: stdout,
      stderr: stderr,
      exit_code: result.exit_code,
      duration_ms: result.duration_ms,
      workspace_files: workspace_files,
      execution_id: Map.get(result, :execution_id),
      hint:
        "Interpret results for the user. Summarize output, don't dump it raw. Files are shown to the user with download buttons automatically."
    }

    response = if truncated, do: Map.put(response, :output_truncated, true), else: response

    # For silent commands with empty output, override hint
    response =
      if String.trim(stdout) == "" and String.trim(stderr) == "" and
           silent_command?(command) do
        Map.put(
          response,
          :hint,
          "Done. Command completed successfully with no output (this is expected)."
        )
      else
        response
      end

    # Add exit code interpretation for non-zero codes
    case interpret_exit_code(command, result.exit_code) do
      nil -> response
      interpretation -> Map.put(response, :exit_code_meaning, interpretation)
    end
  end

  defp format_timeout(partial) when is_map(partial) do
    %{
      success: false,
      stdout: Map.get(partial, :stdout, "") || "",
      stderr: "Command timed out after the maximum allowed time.",
      error_type: "timeout",
      hint: "The command took too long. Try a simpler command or break it into smaller steps."
    }
  end

  defp format_timeout(_), do: format_timeout(%{})

  defp format_oom(partial) when is_map(partial) do
    %{
      success: false,
      stdout: Map.get(partial, :stdout, "") || "",
      stderr: "Out of memory. The command used more than 512MB of RAM.",
      error_type: "oom",
      hint: "Try processing less data or using more memory-efficient approaches."
    }
  end

  defp format_oom(_), do: format_oom(%{})

  defp format_error(%{__struct__: _} = error) do
    message =
      case error do
        %{message: msg} when is_binary(msg) -> msg
        %{__exception__: true} -> Exception.message(error)
        _ -> inspect(error)
      end

    %{
      success: false,
      stdout: "",
      stderr: message,
      error_type: "internal_error",
      hint: "An internal error occurred. Please try again."
    }
  end

  defp format_error(details) when is_map(details) do
    %{
      success: false,
      stdout: Map.get(details, :stdout, "") || "",
      stderr: Map.get(details, :stderr, "") || inspect(details),
      error_type: "runtime_error",
      hint: "Review the error output, fix the issue, and retry."
    }
  end

  defp format_error(details) do
    %{
      success: false,
      stdout: "",
      stderr: inspect(details),
      error_type: "unknown_error",
      hint: "An unexpected error occurred. Try again."
    }
  end

  @doc false
  def interpret_exit_code(command, exit_code) do
    cmd_name =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> Path.basename()

    cond do
      exit_code == 0 ->
        nil

      cmd_name in ["grep", "rg", "ag", "ack"] and exit_code == 1 ->
        "No matches found (not an error)"

      cmd_name == "diff" and exit_code == 1 ->
        "Files differ (not an error)"

      cmd_name == "test" and exit_code == 1 ->
        "Test condition is false"

      exit_code == 126 ->
        "Permission denied (not executable)"

      exit_code == 127 ->
        "Command not found"

      exit_code == 137 ->
        "Killed (likely OOM or timeout signal)"

      exit_code == 139 ->
        "Segmentation fault"

      exit_code == 143 ->
        "Terminated by signal"

      true ->
        nil
    end
  end

  defp silent_command?(command) do
    cmd_name =
      command
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> Path.basename()

    cmd_name in @silent_commands
  end

  defp truncate(s, max) when is_binary(s) and byte_size(s) > max do
    String.slice(s, 0, max - 3) <> "..."
  end

  defp truncate(s, _max), do: s
end
