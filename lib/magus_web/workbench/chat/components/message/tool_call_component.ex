defmodule MagusWeb.ChatLive.Components.Message.ToolCallComponent do
  @moduledoc """
  Component for rendering rich tool call displays matching Claude Code's UI style.

  Shows tool name, inputs inline, result summaries, and expandable details.
  Dispatches to specialized components for certain tool types (e.g., code execution).

  Tool events render through the `:messages` stream — both ephemeral (real-time)
  and persisted events use the same `tool_call_entry/1` component via `event_message/1`.

  ## Extensibility

  To add a specialized component for a new tool type:
  1. Create a new component module (e.g., `MyToolComponent`)
  2. Add the tool name(s) to `specialized_tool_type/1`
  3. Add a clause to `render_specialized/1` to render your component
  """
  use MagusWeb, :html

  alias MagusWeb.ChatLive.Components.Message.CodeExecutionComponent
  alias MagusWeb.ChatLive.Components.Message.CollapsibleSection

  # ============================================================================
  # Tool Call Entry (Single tool display)
  # ============================================================================

  attr :tool_call_data, :map, required: true
  attr :id, :string, required: true

  def tool_call_entry(assigns) do
    # Handle both atom and string keys in tool_call_data
    data = normalize_tool_call_data(assigns.tool_call_data)
    tool_type = specialized_tool_type(data.tool_name)
    has_details = has_expandable_details?(data)

    assigns = assign(assigns, data: data, tool_type: tool_type, has_details: has_details)

    ~H"""
    <%= if @tool_type && (@data.status != :in_progress || @tool_type in [:sub_agent, :sandbox]) do %>
      <.render_specialized
        tool_type={@tool_type}
        data={@data}
        id={@id}
        tool_call_data={@tool_call_data}
      />
    <% else %>
      <.generic_tool_call data={@data} id={@id} has_details={@has_details} />
    <% end %>
    """
  end

  # Dispatch to specialized component based on tool type
  attr :tool_type, :atom, required: true
  attr :data, :map, required: true
  attr :id, :string, required: true
  attr :tool_call_data, :map, required: true

  defp render_specialized(%{tool_type: :service_started, data: %{status: :error}} = assigns) do
    ~H"""
    <div id={@id} class="tool-call-entry py-3 px-4 ml-2 bg-base-200/30 rounded-lg max-w-lg">
      <div class="flex items-center gap-2 text-sm">
        <.icon name="lucide-alert-circle" class="w-4 h-4 shrink-0 text-error" />
        <span class="font-medium text-base-content/80">Service Failed</span>
        <span class="badge badge-error badge-xs">error</span>
      </div>
      <div :if={@data.error} class="mt-1 text-xs text-error/80">{@data.error}</div>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :service_started} = assigns) do
    service_data = extract_service_data(assigns.data)
    assigns = assign(assigns, service: service_data)

    ~H"""
    <div id={@id} class="tool-call-entry py-3 px-4 ml-2 bg-base-200/30 rounded-lg max-w-lg">
      <div class="flex items-center gap-2 text-sm">
        <.icon name="lucide-globe" class="w-4 h-4 shrink-0 text-success" />
        <span class="font-medium text-base-content/80">{gettext("Service Running")}</span>
      </div>
      <div :if={@service.preview_url} class="mt-2">
        <button
          type="button"
          phx-click="open_service_pane"
          class="btn btn-sm btn-outline btn-primary gap-1"
        >
          <.icon name="lucide-panel-right" class="w-3.5 h-3.5" />
          {gettext("View in Pane")}
        </button>
      </div>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :file_download, data: %{status: :error}} = assigns) do
    file_data = extract_file_download_data(assigns.data)
    assigns = assign(assigns, file: file_data)

    ~H"""
    <div id={@id} class="flex items-center gap-2 py-1 px-3 ml-2 text-xs text-error/70">
      <.icon name="lucide-file-x" class="w-3.5 h-3.5 shrink-0" />
      <span class="truncate">{@file.error || "File not found"}</span>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :file_download} = assigns) do
    file_data = extract_file_download_data(assigns.data)
    assigns = assign(assigns, file: file_data)

    ~H"""
    <div id={@id} class="tool-call-entry py-3 px-4 ml-2 bg-base-200/30 rounded-lg max-w-lg">
      <div class="flex items-center gap-2 text-sm">
        <.icon name={file_icon(@file.mime_type)} class="w-4 h-4 shrink-0 text-primary" />
        <span class="font-medium text-base-content/80">{@file.filename}</span>
        <span :if={@file.size_text} class="text-base-content/50 text-xs">{@file.size_text}</span>
      </div>
      <div :if={@file.download_url} class="mt-2 flex items-center gap-2">
        <a
          href={@file.download_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-sm btn-outline btn-primary gap-1"
        >
          <.icon name="lucide-download" class="w-3.5 h-3.5" /> Download
        </a>
        <button
          :if={@file.mime_type == "application/pdf"}
          type="button"
          phx-click="open_pdf_pane"
          phx-value-file-id={@file.file_id}
          phx-value-name={@file.filename}
          phx-value-url={@file.download_url}
          class="btn btn-sm btn-outline btn-primary gap-1"
        >
          <.icon name="lucide-eye" class="w-3.5 h-3.5" /> Preview
        </button>
      </div>
      <div :if={@file.error} class="mt-1 text-xs text-error">{@file.error}</div>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :write_draft} = assigns) do
    draft_data = extract_write_draft_data(assigns.data)
    assigns = assign(assigns, draft: draft_data)

    ~H"""
    <div id={@id} class="tool-call-entry py-3 px-4 ml-2 bg-base-200/30 rounded-lg max-w-lg">
      <div class="flex items-center gap-2 text-sm">
        <.icon name="lucide-file-text" class="w-4 h-4 shrink-0 text-primary" />
        <span class="font-medium text-base-content/80">{@draft.title}</span>
        <span class="badge badge-xs badge-ghost font-mono">v{@draft.version}</span>
        <span class="badge badge-xs badge-outline">{@draft.mode}</span>
      </div>
      <div :if={@draft.line_count} class="mt-1 text-xs text-base-content/50">
        {pluralize_lines(@draft.line_count)}
        <span :if={@draft.edited_range}>
          (lines {@draft.edited_range})
        </span>
      </div>
      <div class="mt-2">
        <button
          type="button"
          phx-click="open_draft_pane"
          phx-value-draft-id={@draft.draft_id}
          class="btn btn-sm btn-outline btn-primary gap-1"
        >
          <.icon name="lucide-panel-right" class="w-3.5 h-3.5" /> View Draft
        </button>
      </div>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :sub_agent} = assigns) do
    sub_agent = extract_sub_agent_data(assigns.data)
    last_step = List.last(assigns.data.steps || [])

    preview =
      cond do
        sub_agent.result_text ->
          sub_agent.result_text
          |> String.replace("\n", " ")
          |> String.slice(0, 80)

        last_step && last_step.label ->
          String.slice(last_step.label, 0, 80)

        sub_agent.objective ->
          String.slice(sub_agent.objective, 0, 80)

        true ->
          nil
      end

    has_details =
      sub_agent.result_text != nil or sub_agent.objective != nil or assigns.data.steps != []

    assigns =
      assign(assigns,
        sub_agent: sub_agent,
        preview: preview,
        has_details: has_details
      )

    ~H"""
    <div id={@id} class="tool-call-entry ml-2">
      <%= if @has_details do %>
        <details class="group" open={@data.status == :in_progress}>
          <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
            <.status_indicator status={@data.status} />
            <span>Sub-agent</span>
            <pre
              :if={@preview}
              class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md"
            >{@preview}</pre>
          </summary>
          <div
            id={"#{@id}-content"}
            class="mt-2 ml-2 border-l border-base-300 pl-3 space-y-2 max-h-96 overflow-y-auto"
            phx-hook="AutoScrollContent"
          >
            <div :if={@sub_agent.objective} class="space-y-1">
              <details class="group/prompt">
                <summary class="flex items-center gap-1.5 text-xs text-base-content/40 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden hover:text-base-content/60">
                  <.icon name="lucide-scroll-text" class="w-3 h-3 shrink-0" /> View prompt
                </summary>
                <div class="mt-1 text-xs text-base-content/60 whitespace-pre-wrap">
                  {@sub_agent.objective}
                </div>
              </details>
            </div>
            <div :if={@data.steps != []} class="space-y-0.5">
              <.sub_agent_step :for={step <- @data.steps} step={step} id={@id} />
            </div>
            <div
              :if={@sub_agent.result_text}
              class="prose prose-sm dark:prose-invert max-w-none text-xs"
            >
              {to_markdown(@sub_agent.result_text)}
            </div>
          </div>
        </details>
      <% else %>
        <div class="flex items-center gap-2 text-sm text-base-content/50">
          <.status_indicator status={@data.status} />
          <span>Sub-agent</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :await_sub_agents} = assigns) do
    results = extract_await_results(assigns.data)
    assigns = assign(assigns, results: results)

    ~H"""
    <div id={@id} class="tool-call-entry ml-2">
      <%= if @results == [] do %>
        <div class="flex items-center gap-2 text-sm text-base-content/50">
          <.status_indicator status={@data.status} />
          <span>Await sub-agents</span>
          <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{@data.output_summary}</pre>
        </div>
      <% else %>
        <details class="group">
          <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
            <.status_indicator status={@data.status} />
            <span>Await sub-agents</span>
            <pre class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md">{length(@results)} sub-agent(s) returned</pre>
          </summary>
          <div class="mt-2 ml-2 border-l border-base-300 pl-3 space-y-1">
            <.await_result_entry
              :for={{result, idx} <- Enum.with_index(@results)}
              result={result}
              id={"#{@id}-result-#{idx}"}
            />
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  defp render_specialized(%{tool_type: :sandbox, data: %{status: status}} = assigns)
       when status != :in_progress do
    result = extract_code_execution_result(assigns.data)
    assigns = assign(assigns, result: result)

    ~H"""
    <CodeExecutionComponent.code_execution_result result={@result} id={@id} />
    """
  end

  defp render_specialized(%{tool_type: :sandbox} = assigns) do
    steps = assigns.data.steps || []
    assigns = assign(assigns, steps: steps)

    ~H"""
    <div id={@id} class="tool-call-entry ml-2">
      <div class="space-y-1">
        <.sandbox_step :for={step <- @steps} step={step} id={@id} />
        <div :if={@steps == []} class="flex items-center gap-2 text-sm text-base-content/50">
          <.icon name="lucide-refresh-cw" class="w-4 h-4 animate-spin text-info shrink-0" />
          <span>{format_tool_name(@data.tool_name)}</span>
        </div>
      </div>
    </div>
    """
  end

  # Fallback for unknown specialized types (shouldn't happen, but safe)
  defp render_specialized(assigns) do
    ~H"""
    <.generic_tool_call data={@data} id={@id} has_details={true} />
    """
  end

  # Generic tool call display (used for non-specialized tools or in-progress state)
  attr :data, :map, required: true
  attr :id, :string, required: true
  attr :has_details, :boolean, required: true

  defp generic_tool_call(assigns) do
    ~H"""
    <div id={@id} class="tool-call-entry ml-2">
      <%= if @data.status == :in_progress do %>
        <%!-- In-progress: show tool name and streaming progress items --%>
        <div class="flex items-center gap-2 text-sm text-base-content/50">
          <.status_indicator status={@data.status} />
          <span>{format_tool_name(@data.tool_name)}</span>
        </div>
        <div :if={@data.progress_items != []} class="ml-6 mt-1 space-y-1">
          <.progress_item :for={item <- @data.progress_items} item={item} />
        </div>
        <div :if={@data[:accumulated_output]} class="ml-6 mt-2 max-h-64 overflow-y-auto">
          <pre class="text-xs font-mono bg-base-300 rounded-lg p-3 whitespace-pre-wrap break-words">{@data[:accumulated_output]}</pre>
        </div>
      <% else %>
        <%!-- Completed: clickable summary with output preview --%>
        <details :if={@has_details} class="group">
          <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
            <.status_indicator status={@data.status} />
            <span>{format_tool_name(@data.tool_name)}</span>
            <pre
              :if={@data.output_summary && @data.output_summary != ""}
              class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md"
            >{@data.output_summary}</pre>
          </summary>
          <div class="mt-2 ml-2 space-y-2 text-xs border-l border-base-300 pl-3">
            <%!-- Progress items from execution (if multiple steps occurred) --%>
            <div :if={@data.progress_items != []} class="space-y-1">
              <.progress_item :for={item <- @data.progress_items} item={item} />
            </div>
            <%!-- Inputs --%>
            <div :if={@data.inputs != %{}} class="space-y-1">
              <div class="text-base-content/50">Inputs:</div>
              <CollapsibleSection.code_block
                content={format_json(@data.inputs)}
                id={"#{@id}-inputs"}
              />
            </div>
            <%!-- Output --%>
            <div :if={@data.output} class="space-y-1">
              <div class="text-base-content/50">Output:</div>
              <CollapsibleSection.code_block
                content={format_output(@data.output)}
                id={"#{@id}-output"}
              />
            </div>
            <%!-- Error --%>
            <div :if={@data.error} class="space-y-1">
              <div class="text-error/70">Error:</div>
              <CollapsibleSection.code_block
                content={@data.error}
                variant={:error}
                id={"#{@id}-error"}
              />
            </div>
          </div>
        </details>
        <%!-- No details: just show inline --%>
        <div :if={!@has_details} class="flex items-center gap-2 text-sm text-base-content/50">
          <.status_indicator status={@data.status} />
          <span>{format_tool_name(@data.tool_name)}</span>
          <pre
            :if={@data.output_summary && @data.output_summary != ""}
            class="px-2 py-0.5 text-xs text-base-content/40 bg-base-content/5 rounded truncate max-w-md"
          >{@data.output_summary}</pre>
        </div>
      <% end %>
    </div>
    """
  end

  # Determine if a tool should use a specialized component
  # Returns nil for generic tools, or an atom identifying the specialized type
  @spec specialized_tool_type(String.t() | nil) :: atom() | nil
  defp specialized_tool_type(tool_name) when is_binary(tool_name) do
    tool_name_lower = String.downcase(tool_name)

    cond do
      tool_name_lower in [
        "run_code",
        "runcode",
        "run_python",
        "execute_code",
        "exec_command",
        "install_packages"
      ] ->
        :sandbox

      tool_name_lower == "start_service" ->
        :service_started

      tool_name_lower == "sandbox_download_file" ->
        :file_download

      tool_name_lower == "write_draft" ->
        :write_draft

      tool_name_lower == "spawn_sub_agent" ->
        :sub_agent

      tool_name_lower == "await_sub_agents" ->
        :await_sub_agents

      true ->
        nil
    end
  end

  defp specialized_tool_type(_), do: nil

  # Extract code execution result from tool data for the specialized component
  defp extract_code_execution_result(data) do
    output = data.output

    case output do
      %{} = map ->
        # Output is already a map with execution details
        map
        |> Map.put(:code, get_code_from_inputs(data.inputs))
        |> Map.put(:duration_ms, data.duration_ms)

      output when is_binary(output) ->
        # String output - use as stdout
        %{
          success: data.status == :success,
          stdout: output,
          stderr: data.error || "",
          code: get_code_from_inputs(data.inputs),
          duration_ms: data.duration_ms,
          files_created: []
        }

      output when is_list(output) ->
        # List output - could be files or other data, format as JSON
        %{
          success: data.status == :success,
          stdout: format_list_output(output),
          stderr: data.error || "",
          code: get_code_from_inputs(data.inputs),
          duration_ms: data.duration_ms,
          files_created: extract_files_from_list(output)
        }

      nil ->
        # No output
        %{
          success: data.status == :success,
          stdout: "",
          stderr: data.error || "",
          code: get_code_from_inputs(data.inputs),
          duration_ms: data.duration_ms,
          files_created: []
        }

      other ->
        # Unknown type - convert to string for display
        %{
          success: data.status == :success,
          stdout: inspect(other, pretty: true),
          stderr: data.error || "",
          code: get_code_from_inputs(data.inputs),
          duration_ms: data.duration_ms,
          files_created: []
        }
    end
  end

  # Format list output for display
  defp format_list_output(list) do
    case Jason.encode(list, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(list, pretty: true)
    end
  end

  # Extract file information from list output if present
  defp extract_files_from_list(list) do
    list
    |> Enum.filter(fn
      %{filename: _} -> true
      %{"filename" => _} -> true
      _ -> false
    end)
  end

  # Extract file download data from tool output
  defp extract_file_download_data(data) do
    output = data.output || %{}

    size_bytes = Map.get(output, :size_bytes) || Map.get(output, "size_bytes")

    %{
      file_id: Map.get(output, :file_id) || Map.get(output, "file_id"),
      filename: Map.get(output, :filename) || Map.get(output, "filename") || "file",
      download_url: Map.get(output, :download_url) || Map.get(output, "download_url"),
      mime_type: Map.get(output, :mime_type) || Map.get(output, "mime_type"),
      size_text: format_file_size(size_bytes),
      error: Map.get(output, :error) || Map.get(output, "error")
    }
  end

  defp format_file_size(nil), do: nil
  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp file_icon(mime_type) do
    case mime_type do
      "application/pdf" -> "lucide-file-text"
      "image/" <> _ -> "lucide-image"
      "text/" <> _ -> "lucide-file-text"
      "application/zip" -> "lucide-file-archive"
      "application/json" -> "lucide-file-json"
      _ -> "lucide-file-down"
    end
  end

  # Extract service data from tool output for the service_started component
  defp extract_service_data(data) do
    output = data.output || %{}

    %{
      preview_url: Map.get(output, :preview_url) || Map.get(output, "preview_url"),
      name: Map.get(output, :service_name) || Map.get(output, "service_name") || "service",
      status: Map.get(output, :status) || Map.get(output, "status") || "running",
      port: Map.get(output, :port) || Map.get(output, "port")
    }
  end

  # Extract write_draft data from tool output
  defp extract_write_draft_data(data) do
    output = data.output || %{}

    %{
      title: Map.get(output, :title) || Map.get(output, "title") || "Draft",
      version: Map.get(output, :version) || Map.get(output, "version") || 1,
      mode: Map.get(output, :mode) || Map.get(output, "mode") || "updated",
      line_count: Map.get(output, :line_count) || Map.get(output, "line_count"),
      edited_range: Map.get(output, :edited_range) || Map.get(output, "edited_range"),
      draft_id: Map.get(output, :draft_id) || Map.get(output, "draft_id")
    }
  end

  # Extract sub-agent metadata from tool inputs/progress/output
  defp extract_sub_agent_data(data) do
    # Data comes from progress_items (real-time) or output (persisted)
    progress_data =
      data.progress_items
      |> Enum.find_value(%{}, fn
        %{type: :spawning, data: d} -> d
        _ -> nil
      end)

    inputs = data.inputs || %{}
    output = data.output || %{}

    # Extract result text, stripping the "Sub-agent result (model):" prefix
    raw_result = Map.get(output, :result) || Map.get(output, "result")

    # Extract model from prefix if present (for existing data)
    prefix_model =
      case raw_result do
        "Sub-agent " <> _ ->
          case Regex.run(~r/^Sub-agent (?:result|failed) \(([^)]+)\)/, raw_result) do
            [_, model] -> model
            _ -> nil
          end

        _ ->
          nil
      end

    result_text =
      case raw_result do
        "Sub-agent result " <> _ ->
          raw_result |> String.replace(~r/^Sub-agent (?:result|failed) \([^)]*\):\s*/, "")

        text when is_binary(text) ->
          text

        _ ->
          nil
      end

    # Prefer the actual model name (from the response message) over the configured model_key
    actual_model_name =
      Map.get(output, :actual_model_name) || Map.get(output, "actual_model_name")

    model_key =
      Map.get(output, :model_key) || Map.get(output, "model_key") ||
        prefix_model ||
        Map.get(progress_data, :agent_name) ||
        Map.get(progress_data, :model) ||
        Map.get(output, :agent_name) || Map.get(output, "agent_name") ||
        Map.get(output, :model) || Map.get(output, "model") ||
        Map.get(inputs, :model_key) || Map.get(inputs, "model_key")

    %{
      objective:
        Map.get(output, :objective) || Map.get(output, "objective") ||
          Map.get(progress_data, :objective) ||
          Map.get(inputs, :objective) || Map.get(inputs, "objective"),
      model_display: actual_model_name || format_model_key(model_key),
      result_text: result_text
    }
  end

  # Extract results from await_sub_agents tool output
  defp extract_await_results(data) do
    output = data.output || %{}
    results = Map.get(output, :results) || Map.get(output, "results") || []

    Enum.map(results, fn r ->
      model_key = Map.get(r, :model_key) || Map.get(r, "model_key")
      duration_ms = Map.get(r, :duration_ms) || Map.get(r, "duration_ms")

      %{
        objective: Map.get(r, :objective) || Map.get(r, "objective"),
        status: to_string(Map.get(r, :status) || Map.get(r, "status") || "unknown"),
        result_text: Map.get(r, :result_text) || Map.get(r, "result_text"),
        error_message: Map.get(r, :error_message) || Map.get(r, "error_message"),
        model_display: format_model_key(model_key),
        duration_text: format_duration_ms(duration_ms)
      }
    end)
  end

  defp format_duration_ms(nil), do: nil
  defp format_duration_ms(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration_ms(ms), do: "#{Float.round(ms / 1000, 1)}s"

  attr :result, :map, required: true
  attr :id, :string, required: true

  defp await_result_entry(assigns) do
    label =
      if assigns.result.objective do
        assigns.result.objective
        |> String.replace("\n", " ")
        |> String.slice(0, 100)
      else
        "Sub-agent"
      end

    status_icon =
      case assigns.result.status do
        "complete" -> "lucide-check"
        "error" -> "lucide-x"
        "timed_out" -> "lucide-clock"
        "cancelled" -> "lucide-ban"
        _ -> "lucide-circle"
      end

    status_color =
      case assigns.result.status do
        "complete" -> "text-success"
        "error" -> "text-error"
        "timed_out" -> "text-warning"
        "cancelled" -> "text-base-content/40"
        _ -> "text-base-content/40"
      end

    assigns =
      assign(assigns, label: label, status_icon: status_icon, status_color: status_color)

    ~H"""
    <details class="group/result">
      <summary class="flex items-center gap-1.5 text-xs text-base-content/50 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden hover:text-base-content/70">
        <.icon name={@status_icon} class={"w-3 h-3 shrink-0 #{@status_color}"} />
        <span class="truncate">{@label}</span>
        <span
          :if={@result.model_display}
          class="text-base-content/30 text-[10px] font-mono shrink-0"
        >
          {@result.model_display}
        </span>
        <span :if={@result.duration_text} class="text-base-content/30 text-[10px] shrink-0">
          {@result.duration_text}
        </span>
      </summary>
      <div class="mt-1 ml-[18px] space-y-1">
        <div
          :if={@result.result_text}
          class="prose prose-sm dark:prose-invert max-w-none max-h-64 overflow-y-auto text-xs"
        >
          {to_markdown(@result.result_text)}
        </div>
        <div :if={@result.error_message} class="text-xs text-error/80">
          {@result.error_message}
        </div>
      </div>
    </details>
    """
  end

  attr :step, :map, required: true
  attr :id, :string, required: true

  defp sub_agent_step(%{step: %{data: %{type: :text}}} = assigns) do
    ~H"""
    <div class="text-xs text-base-content/50 min-h-5">
      <details class="group/text" open={@step.status == :in_progress}>
        <summary class="flex items-center gap-1.5 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <%= case @step.status do %>
            <% :in_progress -> %>
              <span class="loading loading-dots loading-xs shrink-0"></span>
            <% _ -> %>
              <.icon name="lucide-message-square" class="w-3 h-3 text-base-content/40 shrink-0" />
          <% end %>
          <span class="text-base-content/40 hover:text-base-content/60">
            {@step.label || "Responding..."}
          </span>
        </summary>
        <div
          :if={@step.content && @step.content != ""}
          class="ml-[18px] mt-1 prose prose-sm dark:prose-invert max-w-none max-h-48 overflow-y-auto text-xs text-base-content/60"
        >
          {to_markdown(@step.content)}
        </div>
      </details>
    </div>
    """
  end

  defp sub_agent_step(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 text-xs text-base-content/50 min-h-5">
      <%= case @step.status do %>
        <% :in_progress -> %>
          <span class="loading loading-dots loading-xs shrink-0"></span>
        <% :error -> %>
          <.icon name="lucide-x" class="w-3 h-3 text-error shrink-0" />
        <% _ -> %>
          <.icon name="lucide-check" class="w-3 h-3 text-success shrink-0" />
      <% end %>
      <span class="truncate">
        {@step.label || "Working..."}
        <span :if={@step.content && @step.content != ""} class="text-base-content/40">
          — {@step.content}
        </span>
      </span>
    </div>
    """
  end

  attr :step, :map, required: true
  attr :id, :string, required: true

  defp sandbox_step(assigns) do
    has_content = assigns.step.content && assigns.step.content != ""
    assigns = assign(assigns, has_content: has_content)

    ~H"""
    <div class="text-xs text-base-content/50">
      <div class="flex items-center gap-1.5 min-h-5">
        <%= case @step.status do %>
          <% :in_progress -> %>
            <.icon name="lucide-refresh-cw" class="w-3 h-3 animate-spin text-info shrink-0" />
          <% :error -> %>
            <.icon name="lucide-x" class="w-3 h-3 text-error shrink-0" />
          <% _ -> %>
            <.icon name="lucide-check" class="w-3 h-3 text-success shrink-0" />
        <% end %>
        <span class="truncate">
          {@step.label || "Working..."}
          <span
            :if={@step.status not in [:in_progress] && @step.content && @step.content != ""}
            class="text-base-content/40"
          >
            — {String.slice(@step.content, 0, 80)}
          </span>
        </span>
      </div>
      <div
        :if={@has_content && @step.status == :in_progress}
        id={"#{@id}-step-#{@step.index}-output"}
        phx-hook="AutoScrollContent"
        class="ml-[18px] mt-1 max-h-48 overflow-y-auto"
      >
        <pre class="text-xs font-mono bg-base-300 rounded-lg p-2 whitespace-pre-wrap break-words text-base-content/70">{@step.content}</pre>
      </div>
    </div>
    """
  end

  defp pluralize_lines(1), do: "1 line"
  defp pluralize_lines(n), do: "#{n} lines"

  defp get_code_from_inputs(inputs) when is_map(inputs) do
    Map.get(inputs, :code) || Map.get(inputs, "code") || ""
  end

  defp get_code_from_inputs(_), do: ""

  # Check if there's meaningful detail to show when expanded
  defp has_expandable_details?(data) do
    has_inputs = data.inputs != %{} and data.inputs != nil
    has_output = data.output != nil and data.output != ""
    has_error = data.error != nil and data.error != ""
    has_inputs or has_output or has_error
  end

  attr :item, :map, required: true

  defp progress_item(assigns) do
    ~H"""
    <div
      :if={@item.type != :initializing}
      class="flex items-start gap-2 text-xs text-base-content/70 animate-fade-in"
    >
      <span class="text-base-content/40">└</span>
      <div class="flex-1 min-w-0">
        <%= case @item.type do %>
          <% :result_found -> %>
            <div class="flex items-center gap-1.5">
              <.icon name="lucide-link" class="w-3 h-3 text-info/70 shrink-0" />
              <a
                :if={safe_url?(@item.data[:url])}
                href={@item.data[:url]}
                target="_blank"
                rel="noopener noreferrer"
                class="text-info/80 hover:text-info hover:underline truncate"
              >
                {@item.data[:title] || "Result"}
              </a>
              <span :if={!@item.data[:url]} class="truncate">{@item.data[:title] || "Result"}</span>
            </div>
            <p :if={@item.data[:summary]} class="text-base-content/50 text-xs mt-0.5 line-clamp-2">
              {@item.data[:summary]}
            </p>
          <% :preparing -> %>
            <div class="flex items-center gap-1.5">
              <.icon name="lucide-box" class="w-3 h-3 text-info/70 shrink-0" />
              <span class="text-base-content/60">{@item.data[:message] || "Setting up..."}</span>
            </div>
          <% :executing -> %>
            <div class="flex items-center gap-1.5">
              <.icon name="lucide-play" class="w-3 h-3 text-info/70 shrink-0" />
              <span class="text-base-content/60">{@item.data[:message] || "Running code..."}</span>
            </div>
          <% :extracting -> %>
            <div class="flex items-center gap-1.5">
              <.icon name="lucide-file-output" class="w-3 h-3 text-info/70 shrink-0" />
              <span class="text-base-content/60">
                {@item.data[:message] || "Processing files..."}
              </span>
            </div>
          <% _ -> %>
            <div class="flex items-center gap-1.5">
              <.icon name="lucide-activity" class="w-3 h-3 text-base-content/50 shrink-0" />
              <span class="text-base-content/60">{format_progress_data(@item)}</span>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Format progress data for display
  defp format_progress_data(%{data: %{message: message}}) when is_binary(message), do: message

  defp format_progress_data(%{type: type, data: data}) when is_atom(type) do
    case data do
      %{message: msg} when is_binary(msg) -> msg
      _ -> "#{format_atom(type)}..."
    end
  end

  defp format_progress_data(%{data: data}), do: inspect(data)

  defp format_atom(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  attr :status, :atom, required: true

  defp status_indicator(assigns) do
    {icon, class} =
      case assigns.status do
        :in_progress -> {"lucide-refresh-cw", "animate-spin text-info"}
        :success -> {"lucide-check-circle", "text-success"}
        :error -> {"lucide-alert-circle", "text-error"}
        _ -> {"lucide-settings", "text-base-content/50"}
      end

    assigns = assign(assigns, icon: icon, class: class)

    ~H"""
    <.icon name={@icon} class={["w-4 h-4 shrink-0", @class]} />
    """
  end

  # Normalize tool_call_data to handle both atom and string keys
  defp normalize_tool_call_data(data) when is_map(data) do
    %{
      status: get_status(data),
      tool_name: Map.get(data, :tool_name) || Map.get(data, "tool_name") || "unknown",
      display_name: Map.get(data, :display_name) || Map.get(data, "display_name"),
      inputs: Map.get(data, :inputs) || Map.get(data, "inputs") || %{},
      output: Map.get(data, :output) || Map.get(data, "output"),
      output_summary:
        Map.get(data, :output_summary) || Map.get(data, "output_summary") || "Completed",
      duration_ms: Map.get(data, :duration_ms) || Map.get(data, "duration_ms"),
      error: Map.get(data, :error) || Map.get(data, "error"),
      progress_items: Map.get(data, :progress_items) || Map.get(data, "progress_items") || [],
      steps: normalize_steps(Map.get(data, :steps) || Map.get(data, "steps") || []),
      accumulated_output:
        Map.get(data, :accumulated_output) || Map.get(data, "accumulated_output")
    }
  end

  defp normalize_tool_call_data(_),
    do: %{
      status: :error,
      tool_name: "unknown",
      display_name: nil,
      inputs: %{},
      output: nil,
      output_summary: nil,
      duration_ms: nil,
      error: nil,
      progress_items: [],
      steps: []
    }

  defp normalize_steps(steps) when is_list(steps) do
    Enum.map(steps, fn step ->
      %{
        id: Map.get(step, :id) || Map.get(step, "id"),
        index: Map.get(step, :index) || Map.get(step, "index") || 0,
        label: Map.get(step, :label) || Map.get(step, "label"),
        status: normalize_step_status(Map.get(step, :status) || Map.get(step, "status")),
        content: Map.get(step, :content) || Map.get(step, "content") || "",
        data: normalize_step_data(Map.get(step, :data) || Map.get(step, "data"))
      }
    end)
  end

  defp normalize_steps(_), do: []

  defp normalize_step_data(nil), do: %{}

  defp normalize_step_data(data) when is_map(data) do
    type = Map.get(data, :type) || Map.get(data, "type")
    type = if is_binary(type), do: String.to_existing_atom(type), else: type
    %{type: type}
  rescue
    ArgumentError -> %{}
  end

  defp normalize_step_data(_), do: %{}

  defp normalize_step_status(:complete), do: :complete
  defp normalize_step_status("complete"), do: :complete
  defp normalize_step_status(:error), do: :error
  defp normalize_step_status("error"), do: :error
  defp normalize_step_status(:in_progress), do: :in_progress
  defp normalize_step_status("in_progress"), do: :in_progress
  defp normalize_step_status(_), do: :complete

  defp get_status(data) do
    case Map.get(data, :status) || Map.get(data, "status") do
      :in_progress -> :in_progress
      "in_progress" -> :in_progress
      :success -> :success
      "success" -> :success
      :error -> :error
      "error" -> :error
      _ -> :success
    end
  end

  defp format_tool_name(nil), do: "Tool"

  defp format_tool_name(name) when is_binary(name) do
    name
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_tool_name(name), do: to_string(name)

  # Maximum characters for expanded tool output display
  @max_output_length 2000

  defp format_json(data) when is_map(data) do
    json = Jason.encode!(data, pretty: true)
    truncate_output(json)
  rescue
    _ -> truncate_output(inspect(data, pretty: true))
  end

  defp format_json(data), do: truncate_output(inspect(data, pretty: true))

  defp format_output(output) when is_binary(output), do: truncate_output(output)
  defp format_output(output) when is_map(output), do: format_json(output)
  defp format_output(output) when is_list(output), do: format_json(output)
  defp format_output(output), do: truncate_output(inspect(output, pretty: true))

  defp truncate_output(text) when byte_size(text) > @max_output_length do
    String.slice(text, 0, @max_output_length) <> "\n... (truncated)"
  end

  defp truncate_output(text), do: text

  # Validate URLs to prevent javascript: and other unsafe protocols
  defp safe_url?(nil), do: false

  defp safe_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> true
      _ -> false
    end
  end

  defp safe_url?(_), do: false

  # Format model key for display (e.g., "openrouter:anthropic/claude-sonnet-4" → "anthropic/claude-sonnet-4")
  defp format_model_key(nil), do: nil

  defp format_model_key(key) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [_provider, model] -> model
      _ -> key
    end
  end

  defp to_markdown(text) do
    MDEx.to_html(text,
      extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
      parse: [smart: true],
      render: [github_pre_lang: true, unsafe: false],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> case do
      # MDEx output is sanitized at the source (default_sanitize_options +
      # render.unsafe: false), so wrapping in {:safe, _} is XSS-safe here.
      {:ok, html} -> {:safe, html}
      {:error, _} -> text
    end
  end
end
