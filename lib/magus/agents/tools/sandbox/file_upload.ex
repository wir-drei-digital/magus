defmodule Magus.Agents.Tools.Sandbox.FileUpload do
  @moduledoc """
  Jido tool for uploading files into the sandbox filesystem.

  Accepts either a platform File ID (from user attachments) or a URL.
  """

  use Jido.Action,
    name: "sandbox_upload_file",
    description: """
    Upload a file into the sandbox filesystem so you can work with it.

    Two modes:
    - `file_id`: Upload a file the user attached to the conversation. File IDs appear in the message content.
    - `url`: Download a file from a URL and place it in the sandbox.

    Exactly one of `file_id` or `url` must be provided.

    Paths can be absolute or relative to /workspace. Parent directories are created automatically.
    """,
    schema: [
      file_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "ID of a platform file (from user attachments) to upload into the sandbox"
      ],
      url: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "URL to download and upload into the sandbox"
      ],
      path: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Destination path in the sandbox (default: /workspace/{filename})"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Uploading file..."

  def summarize_output(%{filename: filename, size_bytes: size}) do
    "Uploaded #{filename} (#{format_size(size)})"
  end

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        upload_file(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp upload_file(conversation_id, user_id, params, context) do
    case resolve_source(params) do
      {:ok, source} ->
        Signals.emit_tool_progress(context, :uploading, %{
          message: "Uploading file to sandbox..."
        })

        opts = [user_id: user_id] ++ if(params["path"], do: [path: params["path"]], else: [])

        case Orchestrator.upload_file(conversation_id, source, opts) do
          {:ok, result} ->
            {:ok, result}

          {:error, :not_found, message} ->
            {:ok, %{error: message}}

          {:error, :not_configured, _} ->
            {:ok,
             %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

          {:error, _type, details} ->
            {:ok, %{error: inspect(details)}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp resolve_source(%{"file_id" => file_id, "url" => url})
       when not is_nil(file_id) and file_id != "" and not is_nil(url) and url != "" do
    {:error, "Provide either file_id or url, not both."}
  end

  defp resolve_source(%{"file_id" => file_id}) when is_binary(file_id) and file_id != "" do
    {:ok, {:file_id, file_id}}
  end

  defp resolve_source(%{"url" => url}) when is_binary(url) and url != "" do
    {:ok, {:url, url}}
  end

  defp resolve_source(_) do
    {:error, "Provide either file_id (for attached files) or url (for remote files)."}
  end

  defp format_size(nil), do: "unknown"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
