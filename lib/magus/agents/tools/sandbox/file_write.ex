defmodule Magus.Agents.Tools.Sandbox.FileWrite do
  @moduledoc """
  Jido tool for creating or overwriting files in the sandbox.
  """

  use Jido.Action,
    name: "sandbox_write_file",
    description: """
    Create or overwrite a file in the sandbox filesystem.

    Paths can be absolute or relative to /workspace.
    Parent directories are created automatically.

    WARNING: This overwrites the entire file. For targeted edits to existing files,
    use sandbox_edit_file instead -- it's more efficient and less error-prone.

    Use this for:
    - Creating new files (source code, config, scripts, HTML, LaTeX, etc.)
    - Complete file rewrites when most content is changing
    """,
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "File path (absolute or relative to /workspace)"
      ],
      content: [
        type: :string,
        required: true,
        doc: "File contents to write"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, maybe_unescape_content: 1]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Writing file..."

  def summarize_output(%{path: path}), do: "Wrote #{Path.basename(path)}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        write_file(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp write_file(conversation_id, user_id, params, context) do
    path = params["path"]
    content = params["content"] |> maybe_unescape_content()

    Signals.emit_tool_progress(context, :writing, %{
      message: "Writing #{Path.basename(path)}..."
    })

    case Orchestrator.write_file(conversation_id, path, content, user_id: user_id) do
      {:ok, result} ->
        {:ok, %{path: result.path, size_bytes: result.size_bytes}}

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end
end
