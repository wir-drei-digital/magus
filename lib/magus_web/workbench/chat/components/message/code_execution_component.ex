defmodule MagusWeb.ChatLive.Components.Message.CodeExecutionComponent do
  @moduledoc """
  Component for rendering Python code execution results from the sandbox.

  Displays:
  - Executed code with syntax highlighting
  - stdout/stderr output
  - Workspace files with click-to-download buttons
  - Error messages with proper formatting

  If an `execution_id` is provided in the result, the component will fetch the
  executed code from the SandboxExecution record.
  """
  use MagusWeb, :html

  alias Magus.Sandbox
  alias MagusWeb.ChatLive.Components.Message.CollapsibleSection

  require Logger

  attr :result, :map, required: true
  attr :id, :string, required: true

  def code_execution_result(assigns) do
    result = normalize_result(assigns.result)
    output_preview = get_output_preview(result)

    assigns =
      assigns
      |> assign(:result, result)
      |> assign(:output_preview, output_preview)

    ~H"""
    <div id={@id} class="code-execution-result ml-2">
      <details class="group" open={!@result.success}>
        <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <.status_icon success={@result.success} />
          <span>Code Execution</span>
          <pre
            :if={@output_preview != "" && length(@result.files) == 0}
            class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md"
          >{@output_preview}</pre>
        </summary>
        <div class="mt-2 ml-2 space-y-2 text-xs border-l border-base-300 pl-3">
          <%!-- Workspace files (expanded by default, shown first) --%>
          <div :if={length(@result.files) > 0} class="space-y-1">
            <div class="space-y-1">
              <.file_entry :for={file <- @result.files} file={file} />
            </div>
          </div>

          <%!-- Error output --%>
          <div :if={!@result.success} class="mt-1">
            <CollapsibleSection.code_block
              content={first_non_empty([@result.stderr, @result.error, "Execution failed"])}
              variant={:error}
              id={"#{@id}-error"}
            />
          </div>

          <%!-- Stderr output--%>
          <details :if={@result.stderr && @result.stderr != "" && @result.success} class="group/warn">
            <summary class="flex items-center gap-2 text-warning/70 hover:text-warning cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
              <.icon
                name="lucide-chevron-right"
                class="w-3 h-3 group-open/warn:rotate-90 transition-transform"
              />
              <span>Warnings</span>
              <pre class="px-2 py-0.5 text-xs text-warning/50 bg-warning/5 rounded truncate max-w-md">{truncate_line(String.replace(@result.stderr, "\n", " "), 50)}</pre>
            </summary>
            <div class="mt-1 ml-5">
              <CollapsibleSection.code_block
                content={@result.stderr}
                variant={:warning}
                id={"#{@id}-stderr"}
              />
            </div>
          </details>

          <%!-- Stdout output --%>
          <details :if={@result.stdout && @result.stdout != ""} class="group/out">
            <summary class="flex items-center gap-2 text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
              <.icon
                name="lucide-chevron-right"
                class="w-3 h-3 group-open/out:rotate-90 transition-transform"
              />
              <span>Output</span>
              <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{truncate_line(String.replace(@result.stdout, "\n", " "), 50)}</pre>
            </summary>
            <div class="mt-1 ml-5">
              <CollapsibleSection.code_block content={@result.stdout} id={"#{@id}-stdout"} />
            </div>
          </details>

          <%!-- Executed code (collapsed by default with preview) --%>
          <details :if={@result.code && @result.code != ""} class="group/code">
            <summary class="flex items-center gap-2 text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
              <.icon
                name="lucide-chevron-right"
                class="w-3 h-3 group-open/code:rotate-90 transition-transform"
              />
              <span>Code</span>
              <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{truncate_line(String.replace(@result.code, "\n", " "), 50)}</pre>
            </summary>
            <div class="mt-1 ml-5">
              <CollapsibleSection.code_block
                content={@result.code}
                id={"#{@id}-code"}
                language="python"
              />
            </div>
          </details>
        </div>
      </details>
    </div>
    """
  end

  # Get a brief preview of the output for inline display
  defp get_output_preview(result) do
    cond do
      !result.success ->
        error_text = first_non_empty([result.stderr, result.error, "Failed"])
        truncate_line(String.replace(error_text, "\n", " "), 60)

      result.stdout && result.stdout != "" ->
        truncate_line(String.replace(result.stdout, "\n", " "), 60)

      length(result.files) > 0 ->
        files_summary(result.files)

      true ->
        "Success"
    end
  end

  attr :file, :map, required: true

  defp file_entry(assigns) do
    ~H"""
    <%!-- Already downloaded: entire row is a download link --%>
    <a
      :if={@file.download_url}
      href={@file.download_url}
      download={@file.filename}
      class="flex items-center gap-2 text-xs bg-base-300/30 hover:bg-base-300/50 rounded px-2 py-1.5 cursor-pointer transition-colors group"
    >
      <.file_icon mime_type={@file.mime_type} />
      <span class="flex-1 truncate text-base-content/80">{@file.filename}</span>
      <span :if={@file.size_bytes} class="text-base-content/40">
        ({format_size(@file.size_bytes)})
      </span>
      <.icon name="lucide-download" class="w-3.5 h-3.5 text-info group-hover:text-info/80" />
    </a>
    <%!-- Not yet downloaded: entire row is a download button --%>
    <div class="w-full pr-12">
      <button
        :if={!@file.download_url && @file.sandbox_path}
        phx-click="download_sandbox_file"
        phx-value-path={@file.sandbox_path}
        class="flex items-center gap-2 text-xs bg-base-300/30 hover:bg-base-300/50 rounded px-2 py-1.5 cursor-pointer transition-colors group w-full text-left"
      >
        <.file_icon mime_type={@file.mime_type} />
        <span class="flex-1 truncate text-base-content/80">{@file.filename}</span>
        <span :if={@file.size_bytes} class="text-base-content/40">
          ({format_size(@file.size_bytes)})
        </span>
        <.icon name="lucide-download" class="w-3.5 h-3.5 text-info group-hover:text-info/80" />
      </button>
    </div>
    """
  end

  attr :success, :boolean, required: true

  defp status_icon(assigns) do
    {icon, class} =
      if assigns.success do
        {"lucide-check-circle", "text-success"}
      else
        {"lucide-alert-circle", "text-error"}
      end

    assigns = assign(assigns, icon: icon, class: class)

    ~H"""
    <.icon name={@icon} class={["w-4 h-4", @class]} />
    """
  end

  attr :mime_type, :string, default: nil

  defp file_icon(assigns) do
    icon =
      case assigns.mime_type do
        "text/csv" -> "lucide-file-spreadsheet"
        "application/json" -> "lucide-file-json"
        "text/plain" -> "lucide-file-text"
        "text/markdown" -> "lucide-file-text"
        "application/pdf" -> "lucide-file-text"
        "image/" <> _ -> "lucide-file-image"
        "application/vnd.openxmlformats" <> _ -> "lucide-file-spreadsheet"
        "application/vnd.ms-excel" -> "lucide-file-spreadsheet"
        "application/zip" -> "lucide-file-archive"
        _ -> "lucide-file"
      end

    assigns = assign(assigns, icon: icon)

    ~H"""
    <.icon name={@icon} class="w-4 h-4 text-base-content/50" />
    """
  end

  # Normalize result to handle various formats (workspace_files, files_created, registered_files)
  defp normalize_result(result) when is_map(result) do
    code = get_code_from_result_or_execution(result)

    files =
      normalize_files(
        Map.get(result, :workspace_files) ||
          Map.get(result, "workspace_files") ||
          Map.get(result, :files_created) ||
          Map.get(result, "files_created")
      )

    %{
      success: get_bool(result, :success, true),
      stdout: get_string(result, :stdout),
      stderr: get_string(result, :stderr),
      error: get_string(result, :error),
      code: code,
      duration_ms: Map.get(result, :duration_ms) || Map.get(result, "duration_ms"),
      files: files
    }
  end

  defp normalize_result(_), do: %{success: false, stdout: "", stderr: "", code: "", files: []}

  # Get code from result directly, or fetch from SandboxExecution if execution_id is available
  defp get_code_from_result_or_execution(result) do
    case get_string(result, :code) do
      "" -> fetch_code_from_execution(result)
      code -> code
    end
  end

  defp fetch_code_from_execution(result) do
    execution_id = Map.get(result, :execution_id) || Map.get(result, "execution_id")

    if execution_id do
      case Sandbox.get_execution(execution_id, authorize?: false) do
        {:ok, execution} ->
          execution.code || ""

        {:error, reason} ->
          Logger.debug("Could not fetch execution for code display",
            execution_id: execution_id,
            error: inspect(reason)
          )

          ""
      end
    else
      ""
    end
  end

  defp normalize_files(nil), do: []
  defp normalize_files(files) when is_list(files), do: Enum.map(files, &normalize_file/1)
  defp normalize_files(_), do: []

  # Workspace file format: %{name, path, size} or %{"name", "path", "size"}
  defp normalize_file(file) when is_map(file) do
    name = Map.get(file, :name) || Map.get(file, "name")
    path = Map.get(file, :path) || Map.get(file, "path")
    filename = name || Map.get(file, :filename) || Map.get(file, "filename") || "file"
    size = Map.get(file, :size) || Map.get(file, "size")
    size_bytes = size || Map.get(file, :size_bytes) || Map.get(file, "size_bytes")
    mime_type = Map.get(file, :mime_type) || Map.get(file, "mime_type") || guess_mime(filename)

    %{
      filename: filename,
      sandbox_path: path,
      download_url: Map.get(file, :download_url) || Map.get(file, "download_url"),
      mime_type: mime_type,
      size_bytes: size_bytes
    }
  end

  defp normalize_file(filename) when is_binary(filename) do
    %{
      filename: filename,
      sandbox_path: nil,
      download_url: nil,
      mime_type: guess_mime(filename),
      size_bytes: nil
    }
  end

  defp normalize_file(_),
    do: %{filename: "file", sandbox_path: nil, download_url: nil, mime_type: nil, size_bytes: nil}

  defp guess_mime(filename) when is_binary(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".csv" -> "text/csv"
      ".json" -> "application/json"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".svg" -> "image/svg+xml"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".xls" -> "application/vnd.ms-excel"
      ".zip" -> "application/zip"
      ".py" -> "text/x-python"
      _ -> nil
    end
  end

  defp guess_mime(_), do: nil

  # Generate summary for files section
  defp files_summary(files) when is_list(files) do
    count = length(files)

    case count do
      1 ->
        file = hd(files)
        "File: #{file.filename}"

      n ->
        "#{n} files in workspace"
    end
  end

  defp files_summary(_), do: "Files"

  defp truncate_line(line, max_length) do
    if String.length(line) > max_length do
      String.slice(line, 0, max_length - 3) <> "..."
    else
      line
    end
  end

  defp get_bool(map, key, default) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil -> default
      val when is_boolean(val) -> val
      "true" -> true
      "false" -> false
      _ -> default
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil -> ""
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end

  defp format_size(nil), do: nil
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # Return first non-empty string from a list (empty string "" is considered empty)
  defp first_non_empty([]), do: ""
  defp first_non_empty([head | _tail]) when is_binary(head) and head != "", do: head
  defp first_non_empty([_ | tail]), do: first_non_empty(tail)
end
