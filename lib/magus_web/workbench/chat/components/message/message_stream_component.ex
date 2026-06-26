defmodule MagusWeb.ChatLive.Components.Message.MessageStreamComponent do
  @moduledoc """
  LiveComponent for rendering the message stream in a chat conversation.

  Handles:
  - Rendering messages from the stream
  - Thinking indicators (AI processing)
  - Typing indicators (other users in multiplayer)
  - Message alignment (own vs others)
  - Conversation events
  - Message actions (disable, retry)

  Uses `phx-target={@myself}` for message actions.
  Notifies parent via `notify_parent/1` for state changes.
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  import MagusWeb.ChatLive.UI.ChatComponents
  import MagusWeb.ChatLive.UI.EventComponent
  import MagusWeb.ChatLive.Components.Message.ThinkingIndicators
  import MagusWeb.ChatLive.Components.Message.StatusIndicators
  import MagusWeb.ChatLive.Components.Message.MessageItem

  def render(assigns) do
    ~H"""
    <div
      class="flex-1 px-4 py-2 pb-0 flex flex-col-reverse min-w-0 overflow-x-hidden relative"
      id={"#{@id}-stream-container"}
      phx-hook="MessageTextSelection"
    >
      <%!-- Streaming thinking indicator (shown while model is reasoning, hidden when text starts) --%>
      <.streaming_thinking_indicator
        :if={@streaming_thinking && @streaming_thinking != "" && !@is_streaming}
        streaming_thinking={@streaming_thinking}
        is_multiplayer={@is_multiplayer}
      />

      <%!-- Compaction indicator: takes precedence over the thinking dots while
        a compaction is pending/running, explaining the locked composer. Yields
        to the streaming-reasoning indicator above, so the precedence is
        reasoning > compaction > thinking and the three never co-render. The
        suppression reuses the exact condition that shows the streaming-reasoning
        indicator (line above) so the two stay in lockstep. --%>
      <.compacting_indicator compacting={
        @compacting && !(@streaming_thinking && @streaming_thinking != "" && !@is_streaming)
      } />

      <%!-- Thinking indicator shown while waiting for AI response (suppressed
        while compacting so the two never co-render). --%>
      <.response_status_indicator
        waiting={@waiting_for_response and not @compacting}
        streaming={@is_streaming || (@streaming_thinking != nil && @streaming_thinking != "")}
        thinking_status={@thinking_status}
        id={"#{@id}-thinking-indicator"}
      />

      <%!-- Typing indicators for other users in collaborative conversations --%>
      <.user_typing_indicator
        :for={{user_id, user_info} <- @users_typing}
        :if={@is_multiplayer && user_id != @current_user.id}
        user_id={user_id}
        user_info={user_info}
        is_multiplayer={@is_multiplayer}
      />

      <%!--
        Sentinel for "load older messages" pagination. Placed AFTER the
        streamed container in DOM, so flex-col-reverse on the parent puts it
        at the VISUAL TOP of the stream. An IntersectionObserver hook fires
        when the user scrolls up far enough for the sentinel to enter the
        chat scroll viewport.

        Phoenix's built-in `phx-viewport-top`/`phx-viewport-bottom` don't work
        here because they use scrollTop *direction* to gate which event
        fires — and `flex-col-reverse` inverts that mental model relative to
        what the user perceives.
      --%>
      <div
        id={"#{@id}-message-container"}
        phx-update="stream"
        class="flex flex-col-reverse message-stream"
      >
        <%= for {id, item} <- @streams.messages do %>
          <div
            :if={!stream_item_empty?(item)}
            id={id}
            class={stream_item_class(item, @current_user)}
          >
            <%!-- Handle legacy event items (from conversation events) --%>
            <%= if Map.has_key?(item, :event) do %>
              <.conversation_event event={item.event} />
            <% else %>
              <.render_message_item
                item={item}
                is_multiplayer={@is_multiplayer}
                current_user={@current_user}
                target={@myself}
                is_highlighted={@message_highlight == item.id}
                conversation_custom_agent_id={@conversation_custom_agent_id}
                available_agents={@available_agents}
                brain_pane_page_id={@brain_pane_page_id}
              />
            <% end %>
            <%!--
              Context-floor divider. Rendered as the LAST child of the boundary
              item's wrapper, so it sits visually BELOW the message content — the
              boundary is anchored to the last out-of-window message (the newest
              dropped/summarized one), placing the divider between it and the
              first in-window message. The boundary id is only set when
              out-of-window messages are loaded, so the divider shows only when
              there is history to separate; anchoring below the last old message
              also means it surfaces the instant a Clear empties the window.
            --%>
            <.floor_divider
              :if={Map.get(item, :id) == @window_floor_boundary_id}
              id={"#{id}-floor"}
              context_window={@context_window}
            />
          </div>
        <% end %>
      </div>

      <div
        :if={@has_more_messages?}
        id={"#{@id}-load-older-sentinel"}
        phx-hook=".LoadOlderMessages"
        data-loading={if @loading_older_messages?, do: "true", else: "false"}
        class="h-12 flex items-center justify-center text-xs text-wb-text-dim"
      >
        <span :if={@loading_older_messages?}>{gettext("Loading older messages…")}</span>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LoadOlderMessages">
        // px above/below the scroll viewport at which the sentinel counts as
        // "in the trigger zone". Generous so loading kicks in well before the
        // user reaches the very top of content — "smooth and hidden".
        const TRIGGER_MARGIN = 600;

        export default {
          mounted() {
            this.scrollContainer = this.el.closest('[id^="chat-scroll-"]');

            // Disable browser scroll anchoring so scrollTop stays put when
            // content is prepended. The user sees new messages slide in at
            // the visual top (via flex-col-reverse) without any jarring jump.
            if (this.scrollContainer) {
              this.scrollContainer.style.overflowAnchor = "none";
            }

            this.pendingLoad = false;

            this.observer = new IntersectionObserver((entries) => {
              for (const entry of entries) {
                if (
                  entry.isIntersecting &&
                  !this.pendingLoad &&
                  this.el.dataset.loading !== "true"
                ) {
                  this.fireLoad();
                }
              }
            }, { root: this.scrollContainer, rootMargin: `${TRIGGER_MARGIN}px 0px` });
            this.observer.observe(this.el);

            this.handleEvent("older_messages_loaded", (payload) => {
              this.pendingLoad = false;

              // Auto-chain. The sentinel lives at y=0 of chat-scroll content
              // and never moves when stream items are prepended (flex-col-reverse
              // grows the content downward in document coords). Once the user
              // reaches the top, IntersectionObserver won't re-fire because
              // its intersecting state never transitions. We keep firing as
              // long as the load returned items and the sentinel is still in
              // the trigger zone. If the user scrolls away, the chain stops
              // naturally; when history runs out the server flips
              // `has_more_messages?` to false and removes the sentinel from
              // the DOM (hook destroyed).
              if (payload && payload.count > 0) {
                requestAnimationFrame(() => {
                  if (
                    !this.pendingLoad &&
                    this.el.dataset.loading !== "true" &&
                    this.isInTriggerZone()
                  ) {
                    this.fireLoad();
                  }
                });
              }
            });
          },
          fireLoad() {
            this.pendingLoad = true;
            this.pushEvent("load_older_messages", {});
          },
          isInTriggerZone() {
            if (!this.scrollContainer) return true;
            const rect = this.el.getBoundingClientRect();
            const cr = this.scrollContainer.getBoundingClientRect();
            return rect.top - TRIGGER_MARGIN < cr.bottom &&
                   rect.bottom + TRIGGER_MARGIN > cr.top;
          },
          destroyed() {
            if (this.observer) this.observer.disconnect();
          }
        }
      </script>
    </div>
    """
  end

  # Context-floor divider rendered as the FIRST child of the boundary stream
  # item (so it sits visually above the first in-window message). When the
  # window was compacted there is a summary standing in for the older messages:
  # the label becomes a <details> toggle that expands the summary text inline.
  # Otherwise (rolling/cleared, no summary) it stays a plain, non-interactive
  # divider. Re-streaming the boundary message (see
  # `Helpers.restream_floor_boundary/1`) is what makes this surface live.
  attr :id, :string, required: true
  attr :context_window, :map, default: nil

  defp floor_divider(assigns) do
    ~H"""
    <div data-role="context-floor-divider">
      <details :if={floor_has_summary?(@context_window)} id={@id} class="group/floor py-1">
        <summary
          class="flex items-center gap-3 cursor-pointer list-none marker:hidden [&::-webkit-details-marker]:hidden"
          data-role="context-floor-toggle"
        >
          <div class="h-px flex-1 bg-base-300"></div>
          <span class="flex items-center gap-1 text-[11px] text-base-content/60 group-hover/floor:text-base-content/90 transition-colors">
            <.icon
              name="lucide-chevron-right"
              class="w-3 h-3 transition-transform group-open/floor:rotate-90"
            />
            {floor_divider_label(@context_window)}
          </span>
          <div class="h-px flex-1 bg-base-300"></div>
        </summary>
        <div
          class="mt-2 mx-auto max-w-prose whitespace-pre-wrap rounded-md bg-base-200/60 px-3 py-2 text-[11px] leading-relaxed text-base-content/70"
          data-role="context-floor-summary"
        >
          {@context_window.summary}
        </div>
      </details>
      <div :if={!floor_has_summary?(@context_window)} class="flex items-center gap-3 py-1">
        <div class="h-px flex-1 bg-base-300"></div>
        <span class="text-[11px] text-base-content/60">
          {floor_divider_label(@context_window)}
        </span>
        <div class="h-px flex-1 bg-base-300"></div>
      </div>
    </div>
    """
  end

  # Contextual label for the context-floor divider. When the window was
  # compacted (a summary stands in for the older messages) it reads as
  # summarized; otherwise the older messages are simply out of context.
  defp floor_divider_label(cw) do
    if cw && Map.get(cw, :summary_message_count, 0) > 0,
      do: gettext("Older messages summarized"),
      else: gettext("Older messages are out of context")
  end

  # True only when a compaction left a non-empty summary to expand. Gates the
  # interactive <details> vs the plain divider, and guards against a stale
  # `summary_message_count > 0` with a blank/missing summary string.
  defp floor_has_summary?(cw) do
    cw && Map.get(cw, :summary_message_count, 0) > 0 &&
      is_binary(Map.get(cw, :summary)) && Map.get(cw, :summary) != ""
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  def handle_event("toggle_message_disabled", %{"message-id" => message_id}, socket) do
    current_user = socket.assigns.current_user

    case Magus.Chat.get_message(message_id, actor: current_user) do
      {:ok, message} ->
        {:ok, updated} = Magus.Chat.toggle_message_disabled(message, actor: current_user)
        notify_parent({:message_updated, updated})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("retry_message", %{"message-id" => message_id}, socket) do
    notify_parent({:retry_message, message_id})
    {:noreply, socket}
  end

  def handle_event("create_prompt_from_message", %{"message-id" => message_id}, socket) do
    current_user = socket.assigns.current_user

    case Magus.Chat.get_message(message_id, actor: current_user) do
      {:ok, message} ->
        notify_parent({:open_create_prompt_modal, message})
        {:noreply, socket}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  # Catch-all handler for events that may be misrouted during DOM updates
  # (e.g., user_typing from ChatInputComponent during conversation creation)
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end
end
