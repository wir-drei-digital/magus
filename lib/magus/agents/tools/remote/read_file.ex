defmodule Magus.Agents.Tools.Remote.ReadFile do
  @moduledoc """
  Reverse-tunnel proxy tool: reads a file on the *caller's* local machine.

  `run/2` resolves the caller's WebSocket handler from the connection registry
  by the server-side `acting_user_id` (never by anything client-supplied, and
  never by conversation), then does a synchronous `send`/`receive` round-trip
  with a self-enforced timeout. We opt out of the runner's wall-clock
  (`execution_timeout_ms/0` -> :infinity) so our own timeout is the sole
  bound — a runner brutal-kill would surface as a RETRYABLE
  `{:error, %{type: :timeout}}`, which this design must avoid.
  All failures are returned as terminal `{:ok, %{error: ...}}` (never raised,
  never `type: :timeout/:exception`) so the ReAct loop does not retry a
  denied/absent/timed-out call.

  Path scoping and the approval prompt are enforced CLIENT-side by the CLI;
  the returned file content is persisted server-side into the conversation
  (ToolEventPlugin) like any other tool result.
  """

  use Jido.Action,
    name: "read_file",
    description: """
    Read the contents of a file on the user's local machine. The user may be
    prompted to approve access and can deny it. Provide an absolute path or a
    path relative to the user's working directory.
    """,
    schema: [
      path: [type: :string, required: true, doc: "File path to read"]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  alias Magus.Cli.ConnectionRegistry

  # Opt out of the runner's enforced wall-clock (safe_execute_module honors this
  # per-tool override); the proxy's own receive-timeout below is the sole bound.
  def execution_timeout_ms, do: :infinity

  def display_name, do: "Reading local file..."

  def summarize_output(%{content: c}) when is_binary(c),
    do: "#{c |> String.split("\n") |> length()} lines"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    path = get_param(params, :path)

    case validate_context(context, [:acting_user_id]) do
      {:ok, _ctx} when not is_binary(path) or path == "" ->
        {:ok, %{error: "A file path is required."}}

      {:ok, ctx} ->
        round_trip(ctx.acting_user_id, path)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp round_trip(user_id, path) do
    case ConnectionRegistry.lookup(user_id) do
      nil ->
        {:ok,
         %{
           error: "No active local connection for this user.",
           hint: "The user's local agent is not connected; cannot read files now."
         }}

      handler ->
        do_call(handler, path)
    end
  end

  defp do_call(handler, path) do
    call_id = Ecto.UUID.generate()
    ref = Process.monitor(handler)
    send(handler, {:mcp_call, call_id, "read_file", %{path: path}, self()})

    receive do
      {:mcp_result, ^call_id, "ok", result, _error} ->
        Process.demonitor(ref, [:flush])

        {:ok,
         %{
           path: path,
           content: pick(result, "content"),
           truncated: pick(result, "truncated") || false
         }}

      {:mcp_result, ^call_id, "denied", _result, _error} ->
        Process.demonitor(ref, [:flush])

        {:ok,
         %{
           error: "User denied access to #{path}.",
           hint: "Ask the user to approve, or choose another file."
         }}

      {:mcp_result, ^call_id, "error", _result, error} ->
        Process.demonitor(ref, [:flush])
        detail = pick(error || %{}, "message") || "read failed"
        {:ok, %{error: "Could not read #{path}: #{detail}"}}

      # The socket normalizes statuses to ok/denied/error, but this tool must
      # never hang on protocol drift — an unrecognized shape is terminal too.
      {:mcp_result, ^call_id, _status, _result, _error} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{error: "Unexpected reply while reading #{path}."}}

      {:DOWN, ^ref, :process, ^handler, _reason} ->
        {:ok, %{error: "Local connection dropped before #{path} could be read."}}
    after
      timeout_ms() ->
        Process.demonitor(ref, [:flush])
        {:ok, %{error: "Timed out reading #{path} from the local machine."}}
    end
  end

  # Payloads arrive JSON/string-keyed over the WS; the atom branch is a defensive
  # dual-lookup restricted to a fixed whitelist. We never call String.to_atom/1 on
  # arbitrary input (atom-exhaustion safe) and never String.to_existing_atom/1
  # (which raises on an unknown atom — this must never raise).
  defp pick(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, atom_key(key))
  defp pick(_not_a_map, _key), do: nil

  defp atom_key("content"), do: :content
  defp atom_key("truncated"), do: :truncated
  defp atom_key("message"), do: :message
  defp atom_key(_), do: nil

  defp timeout_ms, do: Application.get_env(:magus, :remote_tool_timeout_ms, 30_000)
end
