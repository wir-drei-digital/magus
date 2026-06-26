defmodule MagusWeb.ChatLive.Components.Message.Events do
  @moduledoc """
  Components for rendering event and job trigger messages in the chat stream.

  Includes:
  - Event messages (tool calls, errors, warnings)
  - Job trigger messages with collapsible prompts
  - System event cards with styled icons
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents
  import MagusWeb.ChatLive.UI.ChatComponents, only: [local_timestamp: 1]
  import MagusWeb.ChatLive.Components.Message.ToolCallComponent, only: [tool_call_entry: 1]

  alias MagusWeb.ChatLive.Components.Message.CollapsibleSection

  @doc """
  Renders an event message (e.g., tool calls, errors, warnings) aligned with agent message bubbles.
  Uses rich tool call display when tool_call_data is available, styled card for errors/warnings,
  or simple display for other events.
  """
  attr :item, :map, required: true
  attr :is_multiplayer, :boolean, default: false

  def event_message(assigns) do
    has_tool_data = has_tool_call_data?(assigns.item)
    event_style = detect_event_style(assigns.item.text)
    is_service_preview = is_service_preview?(assigns.item)
    is_thread_announcement = is_thread_announcement?(assigns.item)
    is_wakeup = wakeup_run_id(assigns.item) != nil

    assigns =
      assign(assigns,
        has_tool_data: has_tool_data,
        event_style: event_style,
        is_service_preview: is_service_preview,
        is_thread_announcement: is_thread_announcement,
        is_wakeup: is_wakeup
      )

    ~H"""
    <%= cond do %>
      <% @is_thread_announcement -> %>
        <.thread_announcement_card item={@item} />
      <% @is_wakeup -> %>
        <.wakeup_event_card item={@item} />
      <% @is_service_preview -> %>
        <.tool_call_entry
          tool_call_data={@item.tool_call_data}
          id={"tool-#{@item.id}"}
        />
      <% @has_tool_data -> %>
        <.tool_call_entry
          tool_call_data={@item.tool_call_data}
          id={"tool-#{@item.id}"}
        />
      <% true -> %>
        <.system_event_card
          :if={not String.starts_with?(to_string(@item.text), "Task completed:")}
          item={@item}
          event_style={@event_style}
        />
    <% end %>
    """
  end

  # Renders a wake-up event message (heartbeat / manual_trigger) with a
  # distinct icon and stage-aware styling. Lets users distinguish autonomy
  # traces from regular system events at a glance.
  attr :item, :map, required: true

  defp wakeup_event_card(assigns) do
    metadata = Map.get(assigns.item, :metadata) || %{}
    stage = Map.get(metadata, "wakeup_stage", "running")
    source = Map.get(metadata, "source", "heartbeat")

    {icon, icon_class} =
      case stage do
        "complete" -> {"lucide-zap", "text-success"}
        "skipped" -> {"lucide-zap-off", "text-base-content/40"}
        "failed" -> {"lucide-zap", "text-error"}
        _ -> {"lucide-zap", "text-info"}
      end

    assigns =
      assigns
      |> assign(:icon, icon)
      |> assign(:icon_class, icon_class)
      |> assign(:stage, stage)
      |> assign(:source, source)

    ~H"""
    <div class="tool-call-entry ml-2" data-wakeup-stage={@stage} data-wakeup-source={@source}>
      <div class="flex items-center gap-2 text-xs text-base-content/60 italic">
        <.icon name={@icon} class={["w-3.5 h-3.5 shrink-0", @icon_class]} />
        <span>{@item.text}</span>
      </div>
    </div>
    """
  end

  defp wakeup_run_id(item) do
    case Map.get(item, :metadata) do
      %{"wakeup_run_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  Renders a job trigger message with collapsible trigger prompt.
  Shows job name, optional memory name, timestamp, and expandable prompt text.
  Styled consistently with tool calls.
  """
  attr :item, :map, required: true
  attr :is_multiplayer, :boolean, default: false

  def job_trigger_message(assigns) do
    metadata = Map.get(assigns.item, :metadata, %{})
    job_name = Map.get(metadata, "job_name") || gettext("Scheduled Job")
    memory_name = Map.get(metadata, "memory_name")

    assigns =
      assigns
      |> assign(:job_name, job_name)
      |> assign(:memory_name, memory_name)

    ~H"""
    <div class="ml-2">
      <div class="flex items-center gap-2 text-sm text-base-content/70">
        <.icon name="lucide-play-circle" class="w-4 h-4 text-info shrink-0" />
        <span class="font-medium">{@job_name}</span>
        <span :if={@memory_name} class="text-base-content/50 text-xs truncate">
          ({@memory_name})
        </span>
      </div>
      <CollapsibleSection.collapsible summary={gettext("View trigger prompt")}>
        <:suffix>
          <.local_timestamp
            timestamp={Map.get(@item, :inserted_at)}
            class="text-base-content/40"
          />
        </:suffix>
        <div class="text-sm text-base-content/70 whitespace-pre-wrap">
          {@item.text}
        </div>
      </CollapsibleSection.collapsible>
    </div>
    """
  end

  @doc """
  Renders a draft event message (e.g., review request) with collapsible prompt details.
  Styled consistently with tool call entries.
  """
  attr :item, :map, required: true
  attr :is_multiplayer, :boolean, default: false

  def draft_event_message(assigns) do
    metadata = Map.get(assigns.item, :metadata, %{})
    draft_action = Map.get(metadata, "draft_action", "review")

    label =
      case draft_action do
        "review" -> gettext("Draft Review")
        "approve" -> gettext("Draft Export")
        _ -> gettext("Draft Action")
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    <div class="tool-call-entry ml-2">
      <details class="group">
        <summary class="flex items-center gap-2 text-sm text-base-content/50 hover:text-base-content/70 cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden">
          <.icon name="lucide-scan-search" class="w-4 h-4 text-success" />
          <span>{@label}</span>
        </summary>
        <div class="mt-2 ml-2 space-y-2 text-xs border-l border-base-300 pl-3">
          <div class="text-sm text-base-content/70 whitespace-pre-wrap">
            {@item.text}
          </div>
        </div>
      </details>
    </div>
    """
  end

  # Renders a styled card for system events (errors, warnings, info).
  # Matches the visual style of tool call entries.
  attr :item, :map, required: true
  attr :event_style, :atom, default: :info

  defp system_event_card(assigns) do
    {icon, icon_class, text} = event_display_info(assigns.event_style, assigns.item.text)
    assigns = assign(assigns, icon: icon, icon_class: icon_class, display_text: text)

    ~H"""
    <div class="tool-call-entry ml-2">
      <div class="flex items-center gap-2 text-sm text-base-content/50">
        <.icon name={@icon} class={["w-4 h-4 shrink-0", @icon_class]} />
        <span>{@display_text}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders an action card click as a compact message (similar to tool call styling).
  Used when users click action cards or when wizard "Start" messages are sent.
  """
  attr :item, :map, required: true

  def action_card_message(assigns) do
    ~H"""
    <div class="flex justify-end w-full">
      <div class="flex items-center gap-2 text-sm text-base-content/50 mr-2">
        <span>{@item.text}</span>
        <.icon name="lucide-arrow-right" class="w-3.5 h-3.5 shrink-0" />
      </div>
    </div>
    """
  end

  # Renders a thread announcement as a clickable card linking to the thread conversation.
  attr :item, :map, required: true

  defp thread_announcement_card(assigns) do
    ~H"""
    <div class="my-2">
      <div class="bg-base-200 rounded-lg p-3 border border-primary/20">
        <p class="text-sm mb-2">{@item.text}</p>
        <button
          phx-click="open_thread"
          phx-value-thread-id={get_in(@item.tool_call_data, ["thread_conversation_id"])}
          class="flex items-center gap-2 bg-base-300 rounded-md px-3 py-2 hover:bg-base-100 transition-colors w-full"
        >
          <.icon name="lucide-messages-square" class="w-4 h-4 text-primary" />
          <span class="text-sm text-primary">{gettext("Open thread")}</span>
          <.icon name="lucide-arrow-right" class="w-3 h-3 text-base-content/40 ml-auto" />
        </button>
      </div>
    </div>
    """
  end

  # Check if event is a thread announcement
  defp is_thread_announcement?(item) do
    case Map.get(item, :tool_call_data) do
      %{"thread_announcement" => true} -> true
      _ -> false
    end
  end

  # Check if this is a successful start_service tool call (renders compact card with pane button)
  defp is_service_preview?(item) do
    case Map.get(item, :tool_call_data) do
      %{"tool_name" => "start_service", "status" => status} when status != "error" -> true
      %{tool_name: "start_service", status: status} when status != :error -> true
      _ -> false
    end
  end

  # Check if tool_call_data exists and is not empty
  defp has_tool_call_data?(item) do
    case Map.get(item, :tool_call_data) do
      nil -> false
      data when is_map(data) and data != %{} -> true
      _ -> false
    end
  end

  # Detect the type of event based on text content
  defp detect_event_style(text) when is_binary(text) do
    cond do
      String.contains?(text, ["limit", "exceeded", "reached your", "storage"]) -> :warning
      String.contains?(text, ["error", "Error", "failed", "Failed"]) -> :error
      String.contains?(text, ["timeout", "Timeout", "closed", "Connection"]) -> :error
      true -> :info
    end
  end

  defp detect_event_style(_), do: :info

  # Get display info based on event style
  defp event_display_info(:warning, text) do
    {"lucide-alert-triangle", "text-warning", text}
  end

  defp event_display_info(:error, text) do
    {"lucide-alert-circle", "text-error", text}
  end

  defp event_display_info(:info, text) do
    {event_icon_name(text), "text-base-content/60", text}
  end

  # Get icon name for info-style events based on content
  defp event_icon_name(text) when is_binary(text) do
    cond do
      String.contains?(text, "Search") -> "lucide-search"
      String.contains?(text, "Note") -> "lucide-file-text"
      String.contains?(text, "Dice") -> "lucide-box"
      true -> "lucide-info"
    end
  end

  defp event_icon_name(_), do: "lucide-info"
end
