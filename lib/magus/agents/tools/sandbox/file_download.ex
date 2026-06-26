defmodule Magus.Agents.Tools.Sandbox.FileDownload do
  @moduledoc """
  Jido tool for making sandbox files available for user download.

  Unlike `FileRead` which returns raw content for the LLM, this tool
  persists the file to permanent storage and returns a download URL
  that the user can click to download the file.
  """

  use Jido.Action,
    name: "sandbox_download_file",
    description: """
    Make a sandbox file available for the user to download. Returns a download URL displayed in the chat.

    Use this whenever you create a file the user needs — reports, charts, images, documents, data exports, PDFs, spreadsheets, etc. This provides the best user experience by making the file directly accessible in the conversation.

    Paths can be absolute or relative to /workspace.
    """,
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "File path in the sandbox (absolute or relative to /workspace)"
      ],
      show_in_pane: [
        type: :boolean,
        default: false,
        doc:
          "Open the file in the side pane for interactive viewing. Use for PDFs the user may want to refine."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Preparing download..."

  def summarize_output(%{filename: filename, size_bytes: size}) do
    "#{filename} (#{format_size(size)})"
  end

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        download_file(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp download_file(conversation_id, user_id, params, context) do
    path = params["path"]

    Signals.emit_tool_progress(context, :preparing, %{
      message: "Preparing #{Path.basename(path)} for download..."
    })

    case Orchestrator.download_file(conversation_id, path, user_id: user_id) do
      {:ok, file_info} ->
        shown_in_pane =
          if params["show_in_pane"] && file_info.mime_type == "application/pdf" do
            Magus.Endpoint.broadcast(
              "drafts:conversation:#{conversation_id}",
              "pdf.show",
              %{
                file_id: file_info.id,
                url: file_info.download_url,
                filename: file_info.filename
              }
            )

            true
          else
            false
          end

        {:ok,
         %{
           file_id: file_info.id,
           filename: file_info.filename,
           download_url: file_info.download_url,
           mime_type: file_info.mime_type,
           size_bytes: file_info.size_bytes,
           shown_in_pane: shown_in_pane
         }}

      {:error, :not_found, message} ->
        {:ok, %{error: message, hint: "File not found. Check the path and try again."}}

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end

  defp format_size(nil), do: "unknown"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
