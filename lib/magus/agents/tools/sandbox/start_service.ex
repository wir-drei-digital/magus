defmodule Magus.Agents.Tools.Sandbox.StartService do
  @moduledoc """
  Jido tool for starting a long-running service in the sandbox
  with a private HTTPS URL accessible only to the authenticated user.
  """

  use Jido.Action,
    name: "start_service",
    description: """
    Start a long-running service (web server, API, etc.) in the sandbox and get a
    private preview URL accessible only to the user.

    IMPORTANT: The `command` + `args` must form the FULL runnable command.
    The `args` field is NOT for the port number — it contains the actual
    command-line arguments. The `port` field separately tells the proxy
    which port to forward to.

    Correct examples:
    - Python app:      command "python3", args ["app.py"], port 5000
    - Python server:   command "python3", args ["-m", "http.server", "8000"], port 8000
    - Flask:           command "python3", args ["-m", "flask", "run", "--host=0.0.0.0", "--port=5000"], port 5000
    - Node.js:         command "node", args ["server.js"], port 3000

    WRONG: command "python3", args ["8000"], port 8000
      → This runs "python3 8000" which fails! The args must include the module or script name.

    The returned preview_url can be opened in the browser or embedded as an iframe.

    The PORT environment variable is automatically set to the port value when the service starts.
    Your application should read PORT from the environment or listen on the specified port directly.
    Make sure the service binds to 0.0.0.0 (not just localhost) so the proxy can reach it.
    """,
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Service name (e.g., \"web\", \"api\")"
      ],
      command: [
        type: :string,
        required: true,
        doc: "Command to run (e.g., \"node\", \"python3\")"
      ],
      args: [
        type: {:list, :string},
        required: false,
        default: [],
        doc: "Command arguments (e.g., [\"server.js\"])"
      ],
      port: [
        type: :integer,
        required: true,
        doc: "Port the service listens on"
      ],
      working_dir: [
        type: :string,
        required: false,
        default: "/workspace",
        doc: "Working directory (default: /workspace)"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Starting service..."

  def summarize_output(%{preview_url: url}), do: "Service running at #{url}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        start_service(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp start_service(conversation_id, user_id, params, context) do
    args = params["args"] || []

    # Catch common mistake: args is just a port number like ["8000"]
    if args_look_like_bare_port?(args) do
      {:ok,
       %{
         success: false,
         error:
           "Invalid args #{inspect(args)} — args must be the full command arguments, not just a port number. " <>
             "For example: command \"python3\", args [\"-m\", \"http.server\", \"8000\"], port 8000. " <>
             "Or if serving a script: command \"python3\", args [\"app.py\"], port 5000.",
         hint: "Fix the args and call start_service again."
       }}
    else
      do_start_service(conversation_id, user_id, params, args, context)
    end
  end

  defp args_look_like_bare_port?(args) do
    case args do
      [single] -> String.match?(single, ~r/^\d+$/)
      _ -> false
    end
  end

  defp do_start_service(conversation_id, user_id, params, args, context) do
    service_config = %{
      name: params["name"],
      command: params["command"],
      args: args,
      port: params["port"],
      working_dir: params["working_dir"] || "/workspace"
    }

    Signals.emit_tool_progress(context, :preparing, %{message: "Preparing service..."})

    Signals.emit_tool_progress(context, :starting, %{
      message: "Starting #{service_config.name}..."
    })

    case Orchestrator.start_service(conversation_id, service_config, user_id: user_id) do
      {:ok, result} ->
        {:ok,
         %{
           success: true,
           message:
             "Service '#{service_config.name}' started successfully and is now running on port #{service_config.port}.",
           preview_url: result.preview_url,
           service_name: result.service_name,
           status: result.status,
           port: result.port,
           hint:
             "The service is live. Share the preview_url with the user — it opens in their browser. Do NOT call start_service again or use exec_command to run the same server."
         }}

      {:error, :not_configured, _} ->
        {:ok,
         %{
           success: false,
           error: "Sandbox not configured.",
           hint: "The sandbox service is not available."
         }}

      {:error, :service_error, reason} ->
        {:ok,
         %{
           success: false,
           error: "Failed to start service: #{inspect(reason)}",
           hint: "Check that the command and port are correct."
         }}

      {:error, _type, details} ->
        {:ok, %{success: false, error: inspect(details)}}
    end
  end
end
