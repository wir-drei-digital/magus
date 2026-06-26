defmodule MagusWeb.ChatLive.Components.Threads.ThreadPaneComponent do
  @moduledoc """
  Live component for rendering the thread side pane.

  Displays a thread conversation branched from a message in the parent conversation.
  Includes a header with thread title, branch reference, scrollable message area,
  and the shared ChatInputComponent configured in thread mode.
  """

  use MagusWeb, :live_component

  import MagusWeb.ChatLive.UI.EventComponent
  import MagusWeb.ChatLive.Components.Message.MessageItem
  import MagusWeb.ChatLive.Components.Message.StatusIndicators

  alias MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full min-h-0 border-l border-r border-base-300">
      <%!-- Mobile breadcrumb --%>
      <div class="md:hidden flex items-center gap-2 px-4 py-2 border-b border-base-300 bg-base-100">
        <button
          type="button"
          phx-click="close_thread_pane"
          class="btn btn-ghost btn-xs btn-square"
          title={gettext("Close thread")}
        >
          <.icon name="lucide-arrow-left" class="w-4 h-4" />
        </button>
        <span class="text-sm font-medium truncate">{@thread.title || gettext("Thread")}</span>
      </div>

      <%!-- Header --%>
      <div class="flex items-center min-h-14 justify-between px-4 py-2 border-b border-base-300 bg-base-100/80 backdrop-blur-sm">
        <div class="min-w-0 pr-2">
          <h3 class="text-sm font-medium truncate">{@thread.title || gettext("Thread")}</h3>
          <p :if={@thread.parent_conversation} class="text-xs text-base-content/50 truncate">
            {gettext("Thread in %{name}",
              name: @thread.parent_conversation.title || gettext("Untitled")
            )}
          </p>
        </div>
        <button
          type="button"
          phx-click="close_thread_pane"
          class="btn btn-ghost btn-xs btn-square flex-shrink-0"
          title={gettext("Close thread")}
        >
          <.icon name="lucide-x" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Branch reference --%>
      <div :if={@branched_at_message} class="px-4 py-2 bg-base-200/50 border-b border-base-300">
        <p class="text-[10px] text-base-content/40 uppercase tracking-wide">
          {gettext("Branched from")}
        </p>
        <p class="text-xs text-base-content/60 italic truncate mt-0.5">
          {truncate_text(@branched_at_message.text, 120)}
        </p>
      </div>

      <%!-- Messages: outer wrapper owns the vertical scrolling, inner flex-col
      keeps messages anchored at the top of the pane so a short thread does
      not stick to the bottom. The `WorkbenchScroll` hook keeps the latest
      message in view (auto-scroll) and stops auto-scrolling once the user
      scrolls up. --%>
      <div
        class="flex-1 min-h-0 overflow-y-auto overflow-x-hidden"
        id="thread-messages-container"
        phx-hook="WorkbenchScroll"
        data-scroll-button-id={"thread-scroll-to-bottom-#{@thread.id}"}
      >
        <div class="flex flex-col px-4 py-2 pb-0 min-w-0">
          <div id="thread-messages" phx-update="stream" class="flex flex-col message-stream">
            <%= for {id, item} <- @thread_messages do %>
              <div
                :if={!stream_item_empty?(item)}
                id={id}
                class={stream_item_class(item, @current_user)}
              >
                <%= if Map.has_key?(item, :event) do %>
                  <.conversation_event event={item.event} />
                <% else %>
                  <.render_message_item
                    item={item}
                    is_multiplayer={Map.get(@thread, :is_multiplayer, false)}
                    current_user={@current_user}
                    is_thread_context={true}
                  />
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Thread status indicator below the latest message --%>
          <.response_status_indicator
            waiting={Map.get(assigns, :waiting_for_response, false)}
            streaming={Map.get(assigns, :is_streaming, false)}
            thinking_status={:thinking}
            id="thread-thinking-indicator"
          />
        </div>
      </div>

      <%!-- Input (reuses ChatInputComponent in thread mode) --%>
      <div class="px-2">
        <.live_component
          module={ChatInputComponent}
          id="thread-chat-input"
          input_context={:thread}
          message_form={@message_form}
          conversation_id={@thread.id}
          conversation={@thread}
          current_user={@current_user}
          models={@models}
          selected_model_id={@selected_model_id}
          selected_chat_model_id={@selected_chat_model_id}
          selected_image_model_id={@selected_image_model_id}
          selected_video_model_id={@selected_video_model_id}
          chat_mode={@chat_mode}
          waiting_for_response={Map.get(assigns, :waiting_for_response, false)}
          is_streaming={Map.get(assigns, :is_streaming, false)}
        />
      </div>
    </div>
    """
  end

  defp truncate_text(nil, _max), do: ""

  defp truncate_text(text, max) when is_binary(text) do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end
end
