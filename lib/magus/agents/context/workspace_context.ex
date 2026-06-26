defmodule Magus.Agents.Context.WorkspaceContext do
  @moduledoc """
  Builds workspace context for AI agents from sandbox state.

  Provides context about:
  - Sandbox status (active, suspended, etc.)
  - Files in the workspace
  - Installed packages
  - Last execution time

  This context is injected into the system prompt so agents can continue
  working with existing sandbox state across conversation turns.
  """

  alias Magus.Sandbox

  @doc """
  Build workspace context for a conversation.

  Returns a formatted string describing the sandbox state, or nil if no sandbox exists.
  """
  @spec build(Ecto.UUID.t(), keyword()) :: String.t() | nil
  def build(conversation_id, opts \\ [])

  def build(conversation_id, opts) when is_binary(conversation_id) do
    case Sandbox.get_sandbox_by_conversation(conversation_id, opts) do
      {:ok, [sandbox]} when sandbox.state in [:active, :suspended] ->
        build_context(sandbox, conversation_id)

      {:ok, [%{state: :uninitialized}]} ->
        # Sandbox exists but hasn't been used yet - no context needed
        nil

      {:ok, [%{state: :terminated}]} ->
        # Terminated sandbox - no context
        nil

      {:ok, []} ->
        # No sandbox yet
        nil

      {:error, _} ->
        nil
    end
  end

  def build(_, _), do: nil

  # Build the formatted context string
  defp build_context(sandbox, _conversation_id) do
    files = fetch_workspace_files(sandbox)
    packages = sandbox.installed_packages || []
    last_used = format_last_used(sandbox.last_executed_at)

    """
    ## Active Workspace

    Your sandbox environment is already set up and ready. Continue working with existing files - no need to reinstall packages or recreate files.

    **Status:** #{format_status(sandbox.state)}#{last_used}
    #{format_packages(packages)}#{format_files(files)}
    Use `sandbox_read_file` to view file contents, `sandbox_write_file` to create/modify files, `sandbox_list_files` to list directory contents.
    **Uploading files:** Use `sandbox_upload_file` to copy user-attached files or URL content into the sandbox. Pass the file ID from message attachments, or a URL.
    **Important:** When you create or modify files the user should see or download (reports, images, charts, documents, data exports), use `sandbox_download_file` to make them available. Don't just mention the file — provide the download.
    """
    |> String.trim()
  end

  defp format_status(:active), do: "Active"
  defp format_status(:suspended), do: "Suspended (will resume on next operation)"
  defp format_status(other), do: to_string(other)

  defp format_last_used(nil), do: ""

  defp format_last_used(datetime) do
    relative = relative_time(datetime)
    " (last used #{relative})"
  end

  defp format_packages([]), do: ""

  defp format_packages(packages) do
    package_list = Enum.join(packages, ", ")
    "\n**Installed packages:** #{package_list}\n"
  end

  defp format_files([]), do: "\n**Workspace:** Empty\n"

  defp format_files(files) do
    file_list =
      files
      |> Enum.take(20)
      |> Enum.map_join("\n", fn file ->
        size = format_file_size(file[:size] || 0)
        "- #{file[:path]} (#{size})"
      end)

    remaining = length(files) - 20

    suffix =
      if remaining > 0 do
        "\n- ... and #{remaining} more files"
      else
        ""
      end

    """

    **Files in /workspace:**
    #{file_list}#{suffix}
    """
  end

  # Read from stored workspace_files on sandbox (updated after each execution).
  # Data is normalized to string keys by UpdateWorkspaceFiles change on write.
  defp fetch_workspace_files(sandbox) do
    (sandbox.workspace_files || [])
    |> Enum.map(fn file ->
      %{path: file["path"], size: file["size"] || 0}
    end)
    |> Enum.reject(fn f -> is_nil(f.path) end)
    |> Enum.sort_by(& &1.path)
  end

  defp format_file_size(bytes) when is_number(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_file_size(bytes) when is_number(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_file_size(bytes) when is_number(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_file_size(_), do: "unknown size"

  defp relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        "just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        if minutes == 1, do: "1 minute ago", else: "#{minutes} minutes ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        if hours == 1, do: "1 hour ago", else: "#{hours} hours ago"

      true ->
        days = div(diff_seconds, 86400)
        if days == 1, do: "1 day ago", else: "#{days} days ago"
    end
  end
end
