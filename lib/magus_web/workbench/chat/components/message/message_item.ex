defmodule MagusWeb.ChatLive.Components.Message.MessageItem do
  @moduledoc """
  Shared message rendering component used by both the main message stream
  and the thread pane.

  Handles routing messages by type (event, job_trigger, regular) and rendering
  individual message bubbles with proper alignment, attachments, and actions.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents
  import MagusWeb.ChatLive.UI.ChatComponents
  import MagusWeb.ChatLive.Components.Message.Attachments
  import MagusWeb.ChatLive.Components.Message.ThinkingIndicators
  import MagusWeb.ChatLive.Components.Message.Events
  import MagusWeb.ChatLive.Components.Message.Actions

  import MagusWeb.ChatLive.Helpers,
    only: [has_displayable_content?: 1, has_displayable_content?: 2]

  import MagusWeb.ChatLive.Components.Message.Helpers,
    only: [
      to_markdown: 3,
      get_referenced_citations: 2,
      message_alignment: 3,
      is_own_message?: 2,
      get_message_user_name: 3,
      load_attachments_for_display: 2,
      files_to_display: 1
    ]

  # ============================================================================
  # Message Item Router
  # ============================================================================

  @doc """
  Routes a stream item to the appropriate renderer based on message type.

  Handles legacy events, event messages (tool calls), job triggers,
  draft events, action card clicks, and regular messages.
  """
  attr :item, :map, required: true
  attr :is_multiplayer, :boolean, default: false
  attr :current_user, :map, required: true
  attr :target, :any, default: nil
  attr :is_highlighted, :boolean, default: false
  attr :conversation_custom_agent_id, :string, default: nil
  attr :available_agents, :list, default: []
  attr :is_thread_context, :boolean, default: false
  attr :brain_pane_page_id, :any, default: nil

  def render_message_item(assigns) do
    ~H"""
    <%= case Map.get(@item, :message_type) do %>
      <% :event -> %>
        <.event_message item={@item} is_multiplayer={@is_multiplayer} />
      <% :job_trigger -> %>
        <.job_trigger_message item={@item} is_multiplayer={@is_multiplayer} />
      <% :draft_event -> %>
        <.draft_event_message item={@item} is_multiplayer={@is_multiplayer} />
      <% _ -> %>
        <%= if Map.get(@item, :source) == :user && (Map.get(@item, :metadata) || %{})["action_card"] do %>
          <.action_card_message item={@item} />
        <% else %>
          <.message
            item={@item}
            is_multiplayer={@is_multiplayer}
            current_user={@current_user}
            target={@target}
            is_highlighted={@is_highlighted}
            is_thread_context={@is_thread_context}
            conversation_custom_agent_id={@conversation_custom_agent_id}
            available_agents={@available_agents}
            brain_pane_page_id={@brain_pane_page_id}
          />
        <% end %>
    <% end %>
    """
  end

  # ============================================================================
  # Message Bubble
  # ============================================================================

  @doc """
  Renders a single message bubble with proper alignment and styling.
  """
  attr :item, :map, required: true
  attr :is_multiplayer, :boolean, default: false
  attr :current_user, :map, required: true
  attr :target, :any, default: nil
  attr :is_highlighted, :boolean, default: false
  attr :conversation_custom_agent_id, :string, default: nil
  attr :available_agents, :list, default: []
  attr :is_thread_context, :boolean, default: false
  attr :brain_pane_page_id, :any, default: nil

  def message(assigns) do
    is_disabled = Map.get(assigns.item, :disabled, false)

    loaded_attachments =
      case Map.get(assigns.item, :attachment_resources) do
        %Ash.NotLoaded{} -> load_attachments_for_display(assigns.item, assigns.current_user)
        nil -> load_attachments_for_display(assigns.item, assigns.current_user)
        resources when is_list(resources) -> files_to_display(resources)
      end

    input_images =
      Enum.filter(loaded_attachments, fn a -> a["type"] == "image" end)

    input_files =
      Enum.filter(loaded_attachments, fn a -> a["type"] not in ["image", "video"] end)

    alignment = message_alignment(assigns.item, assigns.is_multiplayer, assigns.current_user)

    has_content = has_displayable_content?(assigns.item, loaded_attachments)

    text = Map.get(assigns.item, :text, "")
    has_text = is_binary(text) and String.trim(text) != ""
    reasoning = Map.get(assigns.item, :reasoning_summary, [])
    has_reasoning = is_list(reasoning) and reasoning != []
    reasoning_only = has_reasoning and not has_text and loaded_attachments == []

    responding_agent_name = extract_agent_name(assigns.item)

    agent_label =
      if responding_agent_name &&
           Map.get(assigns.item, :responding_agent_id) != assigns.conversation_custom_agent_id do
        responding_agent_name
      end

    assigns =
      assigns
      |> assign(:alignment, alignment)
      |> assign(:is_disabled, is_disabled)
      |> assign(:input_files, input_files)
      |> assign(:input_images, input_images)
      |> assign(:loaded_attachments, loaded_attachments)
      |> assign(:has_content, has_content)
      |> assign(:reasoning_only, reasoning_only)
      |> assign(:responding_agent_name, responding_agent_name)
      |> assign(:agent_label, agent_label)

    ~H"""
    <div
      :if={@has_content}
      class={[
        "group overflow-x-auto w-full flex items-end gap-2",
        @alignment,
        @is_multiplayer && "multiplayer",
        @alignment == "start" && "pr-12",
        @alignment == "end" && "pl-12"
      ]}
      data-role={if @item.source == :user, do: "user", else: "agent"}
    >
      <div :if={@is_multiplayer && @item.source == :agent && @has_content} class="avatar">
        <.agent_avatar />
      </div>
      <div
        :if={@is_multiplayer && @item.source == :user && !is_own_message?(@item, @current_user)}
        class="avatar self-start"
      >
        <.chat_user_avatar
          user={@item.created_by}
          is_own_message={is_own_message?(@item, @current_user)}
        />
      </div>

      <div class="flex flex-col overflow-x-auto w-full">
        <.reasoning_display
          :if={@reasoning_only}
          reasoning_summary={Map.get(@item, :reasoning_summary, [])}
        />

        <.message_bubble
          :if={!@reasoning_only}
          user_name={get_message_user_name(@item, @is_multiplayer, @current_user)}
          timestamp={Map.get(@item, :inserted_at)}
          is_highlighted={@is_highlighted}
          agent_label={@agent_label}
        >
          <div class={[@is_disabled && "opacity-50 line-through"]}>
            <.selection_indicators
              :if={@item.source == :user}
              metadata={Map.get(@item, :metadata, %{}) || %{}}
            />

            <% citations = Map.get(@item, :citations, []) %>
            <% referenced_citations = get_referenced_citations(@item.text, citations) %>
            <% is_complete = Map.get(@item, :complete, true) %>
            <div
              id={"message-text-#{@item.id}"}
              phx-hook="RichContent"
              data-complete={"#{is_complete}"}
              class=""
            >
              <div
                id={"message-html-#{@item.id}"}
                class="prose prose-sm prose-a:text-blue-600 prose-a:hover:text-blue-500 dark:prose-invert"
              >
                {to_markdown(@item.text, citations, id: @item.id, agents: @available_agents)}
              </div>
            </div>

            <.image_attachments :if={@item.source == :agent} attachments={@loaded_attachments} />
            <.video_attachments :if={@item.source == :agent} attachments={@loaded_attachments} />

            <.citations_display citations={referenced_citations} />

            <% actions = (Map.get(@item, :metadata) || %{})["action_cards"] %>
            <div :if={actions && @item.source == :agent} class="pt-4">
              <MagusWeb.Components.ActionCards.action_cards
                action_cards={(Map.get(@item, :metadata) || %{})["action_cards"]}
                conversation_id={Map.get(@item, :conversation_id) && to_string(@item.conversation_id)}
              />
            </div>
          </div>
          <:actions>
            <.message_actions_inline
              item={@item}
              is_disabled={@is_disabled}
              target={@target}
              is_thread_context={@is_thread_context}
              brain_pane_page_id={@brain_pane_page_id}
            />
          </:actions>
        </.message_bubble>

        <% thread_count = thread_count(@item) %>
        <% message_count = thread_message_count(@item) %>
        <div :if={!@is_thread_context && thread_count > 0} class="mt-2 pt-2">
          <button
            phx-click="open_thread_from_message"
            phx-value-message-id={@item.id}
            class="flex items-center gap-1.5 text-xs text-primary hover:text-primary-focus transition-colors cursor-pointer"
          >
            <.icon name="lucide-messages-square" class="w-3.5 h-3.5" />
            <span>
              {message_count} {ngettext("reply", "replies", message_count)}
            </span>
          </button>
        </div>

        <.user_attachments
          :if={@item.source == :user && (Enum.any?(@input_files) || Enum.any?(@input_images))}
          files={@input_files}
          images={@input_images}
          alignment={message_alignment(@item, @is_multiplayer, @current_user)}
        />
      </div>
      <div
        :if={@is_multiplayer && @item.source == :user && is_own_message?(@item, @current_user)}
        class="avatar self-start"
      >
        <.chat_user_avatar
          user={@item.created_by}
          is_own_message={is_own_message?(@item, @current_user)}
        />
      </div>
    </div>
    """
  end

  # ============================================================================
  # Selection Indicators
  # ============================================================================

  attr :metadata, :map, required: true

  def selection_indicators(assigns) do
    metadata = assigns.metadata

    indicators =
      []
      |> maybe_add_draft_indicator(metadata)
      |> maybe_add_pdf_indicator(metadata)
      |> maybe_add_service_indicator(metadata)
      |> maybe_add_message_indicators(metadata)

    assigns = assign(assigns, :indicators, indicators)

    ~H"""
    <div :if={@indicators != []} class="flex flex-wrap gap-1 mb-2 -mt-0.5">
      <div
        :for={ind <- @indicators}
        class="flex items-center gap-1.5 bg-base-content/5 rounded px-2 py-0.5 text-xs text-base-content/50 max-w-full"
      >
        <.icon name={ind.icon} class="w-3 h-3 shrink-0" />
        <span :if={ind.label} class="text-base-content/40">{ind.label}</span>
        <span class="truncate">{ind.text}</span>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Checks if a stream item is empty (no displayable content).
  """
  def stream_item_empty?(item) do
    message_type = Map.get(item, :message_type)

    cond do
      Map.has_key?(item, :event) -> false
      message_type in [:job_trigger, :draft_event] -> false
      message_type == :event -> event_renders_empty?(item)
      true -> not has_displayable_content?(item)
    end
  end

  @doc """
  Determines CSS class for a stream item based on message type.
  """
  def stream_item_class(item, current_user) do
    cond do
      Map.has_key?(item, :event) ->
        "msg-type-event"

      Map.get(item, :message_type) == :event ->
        "msg-type-event"

      Map.get(item, :message_type) == :job_trigger ->
        "msg-type-event"

      Map.get(item, :source) == :user && (Map.get(item, :metadata) || %{})["action_card"] ->
        "msg-type-event"

      true ->
        text = Map.get(item, :text, "")
        has_text = is_binary(text) and String.trim(text) != ""
        reasoning = Map.get(item, :reasoning_summary, [])
        has_reasoning = is_list(reasoning) and reasoning != []

        # Only the reasoning-only case depends on whether attachments exist, so
        # resolve them (a policy-checked Ash read) only in that branch. The
        # common text-bearing message skips the read entirely; message/1
        # resolves attachments separately when it actually renders them.
        if has_reasoning and not has_text and not has_attachments?(item, current_user) do
          "msg-type-event"
        else
          "msg-type-bubble"
        end
    end
  end

  defp has_attachments?(item, current_user) do
    case Map.get(item, :attachment_resources) do
      resources when is_list(resources) ->
        resources != []

      _ ->
        case Map.get(item, :attachments, []) || [] do
          [] -> false
          ids -> Magus.Files.load_for_display!(ids, actor: current_user) != []
        end
    end
  end

  # Private helpers

  defp thread_count(item) do
    case Map.get(item, :thread_count) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp thread_message_count(item) do
    case Map.get(item, :thread_message_count) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp extract_agent_name(item) do
    cond do
      name = Map.get(item, :custom_agent_name) -> name
      agent = get_responding_agent(item) -> agent.name
      true -> nil
    end
  end

  defp get_responding_agent(item) do
    case Map.get(item, :responding_agent) do
      %Ash.NotLoaded{} -> nil
      nil -> nil
      agent -> agent
    end
  end

  defp event_renders_empty?(item) do
    no_tool_data =
      case Map.get(item, :tool_call_data) do
        nil -> true
        data when is_map(data) and data != %{} -> false
        _ -> true
      end

    no_tool_data and String.starts_with?(to_string(Map.get(item, :text, "")), "Task completed:")
  end

  defp maybe_add_draft_indicator(acc, %{"draft_selection" => %{"text" => text} = sel})
       when is_binary(text) and text != "" do
    title = sel["draft_title"] || "Draft"
    hint = sel["hint_line"]
    label = if hint, do: "#{title} ~line #{hint}", else: title
    truncated = if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
    acc ++ [%{icon: "lucide-file-pen", label: label, text: truncated}]
  end

  defp maybe_add_draft_indicator(acc, _), do: acc

  defp maybe_add_pdf_indicator(acc, %{"pdf_selection" => %{} = sel}) do
    text = sel["text"] || ""
    filename = sel["filename"] || "PDF"
    page = sel["page"]
    label = if page, do: "#{filename} p.#{page}", else: filename

    if text != "" do
      truncated = if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
      acc ++ [%{icon: "lucide-file-text", label: label, text: truncated}]
    else
      acc ++ [%{icon: "lucide-file-text", label: nil, text: label}]
    end
  end

  defp maybe_add_pdf_indicator(acc, _), do: acc

  defp maybe_add_service_indicator(acc, %{"service_selection" => %{} = sel}) do
    service_name = sel["service_name"] || "Service"
    acc ++ [%{icon: "lucide-globe", label: nil, text: service_name}]
  end

  defp maybe_add_service_indicator(acc, _), do: acc

  defp maybe_add_message_indicators(acc, %{"message_selections" => sels})
       when is_list(sels) and sels != [] do
    items =
      Enum.map(sels, fn sel ->
        text = sel["text"] || ""
        truncated = if String.length(text) > 60, do: String.slice(text, 0, 60) <> "…", else: text
        %{icon: "lucide-quote", label: nil, text: truncated}
      end)

    acc ++ items
  end

  defp maybe_add_message_indicators(acc, _), do: acc
end
