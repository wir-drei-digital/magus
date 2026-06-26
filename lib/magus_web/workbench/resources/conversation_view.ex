defmodule MagusWeb.Workbench.Resources.ConversationView do
  @moduledoc """
  LiveView that renders a conversation inside a workbench tab.

  Mounted via `live_render` from `MagusWeb.Workbench.Tab.TabContainer`
  (non-sticky; the TabContainer is the sticky boundary that survives
  WorkbenchLive navigation). Owns its own PubSub subscriptions for the conversation's
  agent (`agents:<conversation_id>`) and the Jido streaming events. Reuses
  existing ChatLive components (`MessageStreamComponent`, `ChatInputComponent`)
  and PubSub handlers (`MagusWeb.ChatLive.PubSubHandlers`).

  Receives in session:
    - `"conversation_id"` — UUID of the conversation
    - `"user_id"` — UUID of the current user (passed from parent)
    - `"tab_id"` — workbench tab id (used for companion delegation in 3B)

  Auth: the parent WorkbenchLive has already authenticated the user. We look up
  the user by id from the `user_id` session key (bypassing auth tokens, which
  are not forwarded into sticky `live_render` children).
  """
  use MagusWeb, :live_view

  on_mount Magus.Presence

  require Logger

  alias MagusWeb.ChatLive.Components.Brain.BrainSidebarComponent
  alias MagusWeb.ChatLive.Components.ChatInput.ChatInputComponent
  alias MagusWeb.ChatLive.Components.Library.DraftsSidebarComponent
  alias MagusWeb.ChatLive.Components.Library.LibrarySidebarComponent
  alias MagusWeb.ChatLive.Components.Message.MessageStreamComponent
  alias MagusWeb.ChatLive.Components.ShareModalComponent
  alias MagusWeb.ChatLive.Helpers
  alias MagusWeb.ChatLive.PubSubHandlers
  alias MagusWeb.ChatLive.Components.Tasks.TaskPaneComponent
  alias MagusWeb.Workbench.Chat.PendingMessageHighlight
  alias MagusWeb.Workbench.Resources.TaskHandlers
  alias MagusWeb.Workbench.Signals
  alias MagusWeb.Workbench.Tab.RightRail
  alias MagusWeb.Workbench.WorkspaceShare

  import MagusWeb.ChatLive.Helpers, only: [slash_commands_for_agent: 1]
  import MagusWeb.ChatLive.UI.ChatComponents, only: [queued_messages_region: 1]
  import MagusWeb.Components.PresenceIndicator
  import MagusWeb.Workbench.Components.InlineEditActions
  import MagusWeb.Workbench.Components.WorkspaceShareButton

  @impl true
  def mount(_params, %{"conversation_id" => "new"} = session, socket) do
    user_id = session["user_id"]
    tab_id = session["tab_id"]
    workspace_id = session["workspace_id"]
    role = parse_role(session["role"])

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    pending_action = MagusWeb.Workbench.Chat.PendingChatAction.take(user.id)
    agent = pending_agent(pending_action)
    chat_mode = (agent && agent.chat_mode) || :chat

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:conversation, nil)
      |> assign(:conversation_id, "new")
      |> assign(:tab_id, tab_id)
      |> assign(:workspace_id, workspace_id)
      |> assign(:role, role)
      |> assign(:pdf_selection, nil)
      |> assign(:draft_selection, nil)
      |> assign(:brain_selection, normalize_initial_brain_selection(session))
      |> assign(:message_selections, [])
      |> assign(:not_found, false)
      |> assign(:new_chat?, true)
      # Onboarding/announcements/tasks load post-connect via start_async so
      # they don't block first paint. Defaults render the standard returning
      # user view (no first-time flash, empty announcements/tasks).
      |> assign(:undiscovered_features, [])
      |> assign(:first_time?, false)
      |> assign(:announcements, [])
      |> assign(:user_open_tasks, [])
      |> assign(:custom_agent, agent)
      |> assign(:custom_agent_id, agent && agent.id)
      |> assign(:available_agents, [])
      |> init_chat_input_assigns(user, chat_mode, agent: agent)
      |> assign(:message_form, build_new_chat_message_form(user))
      |> allow_upload(:attachments,
        accept: :any,
        max_entries: 20,
        max_file_size: 50_000_000,
        auto_upload: true
      )
      |> apply_pending_chat_action(pending_action)

    socket =
      if connected?(socket) do
        socket
        |> assign(:available_agents, Helpers.load_available_agents(user))
        |> start_async(:load_new_chat_features, fn -> load_new_chat_features(user) end)
        |> start_async(:load_new_chat_announcements, fn ->
          Magus.FeatureUsage.unseen_announcements(user.id)
        end)
        |> start_async(:load_new_chat_open_tasks, fn -> load_open_tasks(user) end)
      else
        socket
      end

    {:ok, socket}
  end

  def mount(_params, session, socket) do
    user_id = session["user_id"]
    conversation_id = session["conversation_id"]
    tab_id = session["tab_id"]
    workspace_id = session["workspace_id"]
    role = parse_role(session["role"])

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    conversation =
      Magus.Chat.get_conversation(conversation_id,
        actor: user,
        load: [
          :message_count,
          :last_message_at,
          :selected_model,
          :is_collaborative,
          :is_shared_to_workspace,
          active_system_prompt: [:model],
          custom_agent: [:image_url]
        ]
      )

    case conversation do
      {:ok, conv} ->
        %{messages: messages, oldest_at: oldest_at, has_more?: has_more?} =
          load_messages(conv, user)

        custom_agent = conv.custom_agent

        is_owner = conv.user_id == user.id

        last_activity_at = conv.last_message_at || conv.updated_at

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:conversation, conv)
         |> assign(:conversation_id, conv.id)
         |> assign(:tab_id, tab_id)
         |> assign(:workspace_id, workspace_id)
         |> assign(:role, role)
         |> assign(:pdf_selection, nil)
         |> assign(:draft_selection, nil)
         |> assign(:brain_selection, normalize_initial_brain_selection(session))
         |> assign(:not_found, false)
         |> assign(:new_chat?, false)
         |> assign(:thinking_status, nil)
         |> assign(:streaming_thinking, nil)
         |> assign(:users_typing, %{})
         |> assign(:message_highlight, PendingMessageHighlight.take(conv.id))
         |> assign(:message_selections, [])
         |> assign(:conversation_custom_agent_id, conv.custom_agent_id)
         |> assign(:custom_agent, custom_agent)
         |> assign(:is_owner, is_owner)
         # Peripheral reads (favorite, share-links, task pane, model catalog,
         # usage state) are deferred to the connected? branch below so the
         # disconnected (static) render stays query-free; these are the
         # skeleton defaults the dead render uses until the live mount fills
         # them in once.
         |> assign(:is_favorited, false)
         |> assign(:has_active_share_links, false)
         |> assign(:show_share_modal, false)
         |> assign(:share_links, [])
         |> assign(:last_activity_at, last_activity_at)
         |> assign(:editing_title?, false)
         |> assign(:available_agents, [])
         |> assign(:brain_pane_page_id, nil)
         |> assign(:conversation_tasks, [])
         # Context-window snapshot (donut + breakdown). nil until the connected
         # branch reads the persisted row; refreshed on `context.updated`.
         |> assign(:context_window, nil)
         # Id of the first in-window message; marks where the context-floor
         # divider renders. nil until the connected branch computes it from the
         # window floor; recomputed on load-older and `context.updated`.
         |> assign(:window_floor_boundary_id, nil)
         |> assign_chat_input_defaults(conv.chat_mode || :chat)
         |> assign(:active_system_prompt, conv.active_system_prompt)
         |> assign(:message_form, build_message_form(conv, user))
         |> allow_upload(:attachments,
           accept: :any,
           max_entries: 5,
           max_file_size: 50_000_000,
           auto_upload: true
         )
         # Streaming state (required by PubSubHandlers)
         |> assign(:active_response_ids, MapSet.new())
         |> assign(:streaming_initialized_ids, MapSet.new())
         |> assign(:streaming_thinking_message_id, nil)
         |> assign(:current_response_message_id, nil)
         |> assign(:streaming_last_render_at, 0)
         # Response-complete assigns
         |> assign(:has_jobs, false)
         # Reset-streaming-state assigns
         |> assign(:tool_event_tracker, %{})
         |> assign(:pane, nil)
         |> assign(:triggering_message_id, nil)
         |> assign(:pending_mention_count, 0)
         |> assign(:active_turn_id, nil)
         |> assign(:active_turn_iteration, nil)
         |> assign(:active_turn_type, nil)
         # Pagination cursor for "load older messages" on scroll-up. `oldest_at`
         # is the inserted_at of the oldest message currently in the stream.
         |> assign(:oldest_message_at, oldest_at)
         |> assign(:has_more_messages?, has_more?)
         |> assign(:loading_older_messages?, false)
         |> stream(:messages, messages)
         |> then(fn socket ->
           if connected?(socket) do
             Phoenix.PubSub.subscribe(Magus.PubSub, "agents:#{conv.id}")
             Phoenix.PubSub.subscribe(Magus.PubSub, "chat:messages:#{conv.id}")
             Phoenix.PubSub.subscribe(Magus.PubSub, "chat:queued:#{conv.id}")
             Phoenix.PubSub.subscribe(Magus.PubSub, "drafts:conversation:#{conv.id}")
             Phoenix.PubSub.subscribe(Magus.PubSub, "tasks:conversation:#{conv.id}")

             # Conversation-level updates (title changes from manual rename
             # or the Oban name_conversation trigger) so the header refreshes
             # without a reload. Published by the Ash pub_sub block on
             # `Magus.Chat.Conversation`.
             Magus.Endpoint.subscribe("chat:conversations:#{conv.id}")

             # Subscribed regardless of collaborative state: an owner unsharing
             # the conversation revokes peer access while peers still have a
             # cached `is_collaborative: true` from mount.
             Phoenix.PubSub.subscribe(Magus.PubSub, "chat:access:#{conv.id}")

             if Helpers.collaborative?(conv) do
               Phoenix.PubSub.subscribe(Magus.PubSub, "chat:typing:#{conv.id}")
             end

             # Subscribe to the tab topic regardless of role: selection
             # broadcasts (PDF / draft / brain) need to land on whichever
             # ConversationView hosts the chat input, which is sometimes
             # the companion (e.g. a brain-primary tab opens chat as a
             # companion). Signals scoped to the primary input only —
             # `:active_prompt` and `:insert_text` — are gated inside
             # their `handle_info` clauses below.
             if tab_id do
               Phoenix.PubSub.subscribe(Magus.PubSub, Signals.tab_topic(tab_id))
             end

             # Peripheral reads run once here, post-connect, so the
             # disconnected (static) render stays query-free. The conversation
             # + messages above are the only synchronous reads (they must
             # render); everything else replaces the skeleton defaults set in
             # the synchronous assigns.
             socket
             |> init_chat_input_assigns(user, conv.chat_mode || :chat)
             |> assign(:queued_messages, Magus.Chat.list_queued_messages!(conv.id, actor: user))
             |> assign(:active_system_prompt, conv.active_system_prompt)
             |> assign(:is_favorited, favorited?(conv, user))
             |> assign(:has_active_share_links, active_share_links?(conv, user))
             |> TaskHandlers.assign_task_pane()
             |> assign(:available_agents, Helpers.load_available_agents(user))
             |> assign(:context_window, load_context_window(conv.id, user))
             |> Helpers.assign_floor_boundary()
           else
             socket
           end
         end)
         |> then(fn socket ->
           if connected?(socket) and socket.assigns.message_highlight do
             Phoenix.LiveView.push_event(socket, "highlight_message", %{
               id: socket.assigns.message_highlight
             })
           else
             socket
           end
         end)
         |> Magus.Presence.track(:conversation, conv.id)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:conversation, nil)
         |> assign(:conversation_id, conversation_id)
         |> assign(:tab_id, tab_id)
         |> assign(:pdf_selection, nil)
         |> assign(:draft_selection, nil)
         |> assign(:brain_selection, nil)
         |> assign(:message_selections, [])
         |> assign(:not_found, true)
         |> assign(:new_chat?, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"conversation-drop-zone-#{resolved_conversation_id(assigns) || "new"}"}
      data-conversation-view
      data-conversation-id={resolved_conversation_id(assigns)}
      class="h-full flex flex-col"
      phx-hook={if @role == :primary, do: "DropZone"}
    >
      <div
        :if={@new_chat?}
        class="flex-1 flex flex-col items-center justify-center px-4 overflow-y-auto"
      >
        <div class="w-full max-w-2xl">
          <MagusWeb.ChatLive.NewChatPage.new_chat_page
            undiscovered_features={@undiscovered_features}
            first_time?={@first_time?}
            announcements={@announcements}
            user_open_tasks={@user_open_tasks}
          />
          <div
            :if={@custom_agent}
            class="mb-3 flex items-center gap-2 text-xs text-wb-text-muted"
          >
            <%= if @custom_agent.image_url do %>
              <img
                src={@custom_agent.image_url}
                class="w-5 h-5 rounded-full object-cover"
                alt={@custom_agent.name}
              />
            <% else %>
              <span class="w-5 h-5 rounded-full bg-wb-surface-2 flex items-center justify-center text-xs">
                {@custom_agent.icon || "🤖"}
              </span>
            <% end %>
            <span>{gettext("Chatting with")} <strong>{@custom_agent.name}</strong></span>
          </div>
          <.live_component
            module={ChatInputComponent}
            id="chat-input-new"
            dom_id_prefix="conv-new-"
            message_form={@message_form}
            conversation_id={nil}
            conversation={nil}
            is_owner={false}
            current_user={@current_user}
            models={models_for_mode(@chat_mode, @chat_models, @image_models, @video_models)}
            selected_model_id={@selected_model_id}
            selected_chat_model_id={@selected_chat_model_id}
            selected_image_model_id={@selected_image_model_id}
            selected_video_model_id={@selected_video_model_id}
            image_generation_settings={@image_generation_settings}
            video_generation_settings={@video_generation_settings}
            context_resources={@context_resources}
            chat_mode={@chat_mode}
            waiting_for_response={@waiting_for_response}
            is_streaming={@is_streaming}
            max_upload_bytes={@max_upload_bytes}
            image_generation_enabled={@image_generation_enabled}
            video_generation_enabled={@video_generation_enabled}
            active_system_prompt={@active_system_prompt}
            message_selections={[]}
            draft_selection={@draft_selection}
            brain_selection={@brain_selection}
            available_agents={@available_agents}
            slash_commands={slash_commands_for_agent(@custom_agent)}
          />
        </div>
      </div>
      <div
        :if={not @new_chat? and @not_found}
        class="flex-1 flex items-center justify-center text-wb-text-muted"
      >
        <p>Conversation not found.</p>
      </div>
      <div
        :if={not @new_chat? and not @not_found}
        class="h-full flex flex-col overflow-hidden min-h-0"
      >
        <.live_component
          :if={@role == :primary}
          module={ShareModalComponent}
          id={"share-modal-#{@conversation.id}"}
          show={@show_share_modal}
          conversation={@conversation}
          share_links={@share_links}
          current_user={@current_user}
        />
        <.chat_header_for_role
          role={@role}
          conversation={@conversation}
          custom_agent={@custom_agent}
          is_owner={@is_owner}
          is_favorited={@is_favorited}
          has_active_share_links={@has_active_share_links}
          last_activity_at={@last_activity_at}
          editing_title?={@editing_title?}
          tab_id={@tab_id}
          user_id={@current_user.id}
          workspace_id={@workspace_id}
          current_user={@current_user}
          viewers={@viewers}
        />
        <div
          id={"chat-scroll-#{@conversation.id}"}
          class="relative flex-1 min-h-0 overflow-y-auto overflow-x-hidden"
          phx-hook="WorkbenchScroll"
          data-scroll-button-id={"scroll-to-bottom-#{@conversation.id}"}
        >
          <div class="max-w-3xl mx-auto w-full h-full">
            <.live_component
              module={MessageStreamComponent}
              id={"messages-#{@conversation.id}"}
              streams={%{messages: @streams.messages}}
              current_user={@current_user}
              is_streaming={@is_streaming}
              waiting_for_response={@waiting_for_response}
              thinking_status={@thinking_status}
              streaming_thinking={@streaming_thinking}
              compacting={compaction_in_progress?(@context_window)}
              users_typing={@users_typing}
              is_multiplayer={@conversation.is_collaborative}
              message_highlight={@message_highlight}
              message_selections={@message_selections}
              conversation_custom_agent_id={@conversation_custom_agent_id}
              available_agents={@available_agents}
              brain_pane_page_id={@brain_pane_page_id}
              has_more_messages?={@has_more_messages?}
              loading_older_messages?={@loading_older_messages?}
              window_floor_boundary_id={@window_floor_boundary_id}
              context_window={@context_window}
            />
          </div>
        </div>
        <div class="shrink-0 sticky bottom-0">
          <div class="max-w-3xl mx-auto w-full relative">
            <button
              id={"scroll-to-bottom-#{@conversation.id}"}
              type="button"
              class="hidden absolute -top-12 right-4 z-10 btn btn-circle btn-sm bg-wb-surface-2 border border-wb-border-strong shadow-md text-wb-text hover:bg-wb-hover"
              title={gettext("Scroll to bottom")}
            >
              <.icon name="lucide-arrow-down" class="w-4 h-4" />
            </button>
            <.queued_messages_region :if={@queued_messages != []} messages={@queued_messages} />
            <.live_component
              module={ChatInputComponent}
              id={"chat-input-#{@conversation.id}"}
              dom_id_prefix={"conv-#{@conversation.id}-"}
              message_form={@message_form}
              conversation_id={@conversation.id}
              conversation={@conversation}
              is_owner={@is_owner}
              current_user={@current_user}
              models={models_for_mode(@chat_mode, @chat_models, @image_models, @video_models)}
              selected_model_id={@selected_model_id}
              selected_chat_model_id={@selected_chat_model_id}
              selected_image_model_id={@selected_image_model_id}
              selected_video_model_id={@selected_video_model_id}
              image_generation_settings={@image_generation_settings}
              video_generation_settings={@video_generation_settings}
              context_resources={@context_resources}
              chat_mode={@chat_mode}
              waiting_for_response={@waiting_for_response}
              is_streaming={@is_streaming}
              active_system_prompt={@active_system_prompt}
              image_generation_enabled={@image_generation_enabled}
              video_generation_enabled={@video_generation_enabled}
              max_upload_bytes={@max_upload_bytes}
              message_selections={@message_selections}
              draft_selection={@draft_selection}
              brain_selection={@brain_selection}
              available_agents={@available_agents}
              conversation_tasks={@conversation_tasks}
              current_user_for_tasks={@current_user}
              context_window={@context_window}
              slash_commands={slash_commands_for_agent(@custom_agent)}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Async load handlers (new-chat post-connect data)
  # ============================================================================

  @impl true
  def handle_async(
        :load_new_chat_features,
        {:ok, %{undiscovered: undiscovered, first_time?: ft}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:undiscovered_features, undiscovered)
     |> assign(:first_time?, ft)}
  end

  def handle_async(:load_new_chat_features, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load_new_chat_announcements, {:ok, announcements}, socket) do
    {:noreply, assign(socket, :announcements, announcements)}
  end

  def handle_async(:load_new_chat_announcements, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load_new_chat_open_tasks, {:ok, tasks}, socket) do
    {:noreply, assign(socket, :user_open_tasks, tasks)}
  end

  def handle_async(:load_new_chat_open_tasks, {:exit, _reason}, socket), do: {:noreply, socket}

  # ============================================================================
  # Event handlers
  # ============================================================================

  @impl true
  # Conversation record updates broadcast by Ash. The per-id topic fires for
  # every update action on the conversation (rename, generate_name,
  # update_visibility, share_to_team, …) with the action name as the event;
  # we react to all of them by re-syncing the title/updated_at fields. Only
  # those two are patched so the existing assign keeps its preloaded
  # associations (custom_agent, selected_model, message_count, …).
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:conversations:" <> _,
          payload: %{__struct__: Magus.Chat.Conversation} = conversation
        },
        socket
      ) do
    current = socket.assigns[:conversation]

    if current && conversation.id == current.id do
      updated = %{current | title: conversation.title, updated_at: conversation.updated_at}
      {:noreply, assign(socket, :conversation, updated)}
    else
      {:noreply, socket}
    end
  end

  # Non-conversation payloads on the same topic (e.g. plain maps used in
  # tests, or future event types) — ignore so they don't surface as
  # unexpected messages.
  def handle_info(%Phoenix.Socket.Broadcast{topic: "chat:conversations:" <> _}, socket) do
    {:noreply, socket}
  end

  def handle_info(
        {ChatInputComponent, {:send_message_with_resources, params, uploaded_resources}},
        %{assigns: %{new_chat?: true}} = socket
      ) do
    text = params["text"] || ""

    if String.trim(text) == "" and uploaded_resources == [] do
      {:noreply, socket}
    else
      all_resources = (socket.assigns.context_resources || []) ++ uploaded_resources

      metadata =
        socket.assigns[:pdf_selection]
        |> build_message_metadata()
        |> attach_message_selections(socket.assigns[:message_selections])
        |> attach_draft_selection(socket.assigns[:draft_selection])

      result =
        Magus.Chat.send_user_message(
          %{
            text: text,
            mode: Helpers.parse_mode(params["mode"]),
            selected_model_id: params["selected_model_id"],
            conversation_id: nil,
            workspace_id: socket.assigns.workspace_id,
            custom_agent_id: socket.assigns[:custom_agent_id],
            system_prompt_id:
              socket.assigns[:active_system_prompt] && socket.assigns.active_system_prompt.id,
            resources: all_resources,
            metadata: metadata
          },
          actor: socket.assigns.current_user
        )

      case result do
        {:ok, message} ->
          new_id = message.conversation_id

          {:noreply,
           socket
           |> assign(:waiting_for_response, true)
           |> assign(:agent_busy?, true)
           |> assign(:pdf_selection, nil)
           |> push_event("clear_message_input", %{target: "conv-new-chat-textarea"})
           |> push_navigate(to: ~p"/chat/#{new_id}")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not send message. Please try again.")}
      end
    end
  end

  def handle_info(
        {ChatInputComponent, {:send_message_with_resources, params, uploaded_resources}},
        socket
      ) do
    text = params["text"] || ""

    cond do
      String.trim(text) == "" and uploaded_resources == [] ->
        {:noreply, socket}

      # Mid-turn steering: while the agent is still working, queue the message
      # instead of dispatching a second turn. The `enqueue_message` broadcast
      # updates `@queued_messages` for the region above the composer.
      #
      # `agent_running?` is phase-level (waiting_for_response/is_streaming) and
      # has gaps within a turn. Tool execution, for instance, clears is_streaming
      # via text.complete and never re-sets waiting_for_response, so the FIRST
      # follow-up sent during a tool call (empty queue) would wrongly dispatch a
      # second turn. `agent_busy?` is the whole-turn flag: it latches on dispatch
      # and on every turn signal, and clears only on the terminal reset, so it
      # stays true across the inter-tool gap. A non-empty queue remains a belt-
      # and-braces signal to preserve ordering once anything is queued.
      agent_busy?(socket) or agent_running?(socket) or socket.assigns.queued_messages != [] ->
        handle_enqueue_while_running(socket, text, params, uploaded_resources)

      true ->
        handle_send_now(socket, text, params, uploaded_resources)
    end
  end

  def handle_info({ChatInputComponent, {:validate_message, _params}}, socket) do
    {:noreply, socket}
  end

  def handle_info({ChatInputComponent, {:flash, type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  # Task pane component events (sent via TaskPaneComponent.notify_parent/1)
  def handle_info({TaskPaneComponent, {:toggle_task, task_id}}, socket) do
    {:noreply, TaskHandlers.handle_toggle_task(socket, task_id)}
  end

  def handle_info({TaskPaneComponent, {:add_task, title, parent_id, assigned_to}}, socket) do
    {:noreply, TaskHandlers.handle_add_task(socket, title, parent_id, assigned_to)}
  end

  def handle_info({TaskPaneComponent, {:update_title, task_id, title}}, socket) do
    {:noreply, TaskHandlers.handle_update_title(socket, task_id, title)}
  end

  def handle_info({TaskPaneComponent, {:reorder_task, task_id, position}}, socket) do
    {:noreply, TaskHandlers.handle_reorder_task(socket, task_id, position)}
  end

  def handle_info({TaskPaneComponent, {:remove_task, task_id}}, socket) do
    {:noreply, TaskHandlers.handle_remove_task(socket, task_id)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "task.created", payload: %{task: _} = payload},
        socket
      ) do
    {:noreply, TaskHandlers.handle_task_created(socket, payload)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "task.updated", payload: %{task: _} = payload},
        socket
      ) do
    {:noreply, TaskHandlers.handle_task_updated(socket, payload)}
  end

  # Message stream notifications: dispatched from MessageStreamComponent
  # via notify_parent/1.
  def handle_info({MessageStreamComponent, {:message_updated, updated_message}}, socket) do
    {:noreply, stream_insert(socket, :messages, updated_message)}
  end

  def handle_info({MessageStreamComponent, {:retry_message, message_id}}, socket) do
    user = socket.assigns.current_user

    with {:ok, message} <- Magus.Chat.get_message(message_id, actor: user),
         {:ok, new_message} <-
           Magus.Chat.send_user_message(
             %{
               text: message.text,
               conversation_id: socket.assigns.conversation.id,
               mode: message.mode
             },
             actor: user
           ) do
      {:noreply,
       socket
       |> assign(:waiting_for_response, true)
       |> assign(:agent_busy?, true)
       |> assign(:thinking_status, :thinking)
       |> stream_insert(:messages, new_message, at: 0)
       |> push_event("scroll_to_bottom", %{force: true})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({MessageStreamComponent, {:open_create_prompt_modal, _message}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       gettext("Creating prompts from messages is coming soon to the workbench.")
     )}
  end

  def handle_info({ShareModalComponent, :share_links_changed}, socket) do
    share_links =
      load_active_share_links(socket.assigns.conversation, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:share_links, share_links)
     |> assign(:has_active_share_links, share_links != [])}
  end

  # Workspace grant on this conversation was revoked. Owners always retain
  # access (the grant only governs non-owner peer reads), so we only act on
  # this for non-owners. Re-fetch the conversation with the current actor;
  # if Ash denies the read, the peer has lost access — navigate them away.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:access:" <> _, event: "access_revoked"},
        socket
      ) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    if conv && conv.user_id != user.id do
      case Magus.Chat.get_conversation(conv.id, actor: user) do
        {:ok, _} ->
          {:noreply, socket}

        {:error, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "You no longer have access to this conversation.")
           |> push_navigate(to: ~p"/chat")}
      end
    else
      {:noreply, socket}
    end
  end

  # Persisted message broadcasts (Ash PubSub on the Message resource).
  # Mirrors `MagusWeb.ChatLive`: surfaces messages from other participants in
  # multiplayer conversations and acts as a safety net if our local
  # stream_insert on send is ever skipped. `stream_insert` is keyed by id, so
  # double inserts of our own messages are deduped.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:messages:" <> conversation_id, payload: message},
        socket
      ) do
    {:noreply, PubSubHandlers.handle_message_broadcast(socket, conversation_id, message)}
  end

  # Queued steering messages (Ash PubSub on the Message resource, `chat:queued:*`
  # topic). The `event` is the action name. `enqueue_message` appends the new
  # queued payload; `flush_queued` / `remove_queued` drop it from the region.
  # Payload keys are atoms (Ash transform), but we read the id defensively.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:queued:" <> _,
          event: "enqueue_message",
          payload: payload
        },
        socket
      ) do
    id = queued_message_id(payload)
    existing = socket.assigns.queued_messages

    # Idempotent append: skip if this id is already in the region (mirrors the
    # SPA reducer's dedup-by-id) so a redelivered broadcast can't duplicate it.
    if Enum.any?(existing, &(queued_message_id(&1) == id)) do
      {:noreply, socket}
    else
      {:noreply, assign(socket, :queued_messages, existing ++ [payload])}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:queued:" <> _, event: event, payload: payload},
        socket
      )
      when event in ["flush_queued", "remove_queued"] do
    id = queued_message_id(payload)
    remaining = Enum.reject(socket.assigns.queued_messages, &(queued_message_id(&1) == id))
    {:noreply, assign(socket, :queued_messages, remaining)}
  end

  # Peer typing indicator (broadcast by ChatInputComponent on keystroke when the
  # conversation is collaborative). `handle_user_typing/5` filters same-user
  # echoes (other tabs/windows of the current user).
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:typing:" <> conversation_id,
          event: "user_typing",
          payload: %{user_id: user_id, is_typing: is_typing} = payload
        },
        socket
      ) do
    {:noreply,
     PubSubHandlers.handle_user_typing(
       socket,
       conversation_id,
       user_id,
       payload,
       is_typing
     )}
  end

  # `draft.created` fires when an agent's `write_draft` tool (or any other
  # path) creates a new draft for this conversation. The `tool.complete` PubSub
  # payload does not include the tool result, so we cannot fish the draft id
  # out there; the dedicated draft topic carries the full draft. Auto-open the
  # companion so the user sees the new document, mirroring legacy behavior.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "drafts:conversation:" <> _,
          event: "draft.created",
          payload: %{draft: draft}
        },
        socket
      ) do
    if tab_id = socket.assigns[:tab_id] do
      MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
        "type" => "draft",
        "id" => draft.id
      })
    end

    {:noreply, socket}
  end

  # Other draft topic events (`draft.updated`, `draft.refined`, etc.) are
  # handled by `DraftCompanion` directly. Swallow them here to avoid
  # noisy unhandled-message logs in the parent LV.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "drafts:conversation:" <> _},
        socket
      ) do
    {:noreply, socket}
  end

  # Agent PubSub streaming events.
  #
  # Magus.Agents.Signals.broadcast/2 uses Magus.Endpoint.broadcast/3, which
  # wraps payloads in a Phoenix.Socket.Broadcast struct. We unwrap once and
  # delegate to the canonical dispatcher in MagusWeb.ChatLive.PubSubHandlers
  # so the workbench gets every signal type the main chat handles (turn.*,
  # state.change, error, run.*, tool.step.*, etc.) without duplication.
  #
  # Workbench-specific UI side effects (opening companions on certain tool
  # completions, intercepting ui.open_brain_pane) layer on top via
  # `maybe_open_companion/2` before the canonical handler runs.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "agents:" <> conversation_id, payload: payload},
        socket
      ) do
    socket =
      case payload do
        %{type: "ui.open_brain_pane", page_id: page_id} when is_binary(page_id) ->
          # Workbench routes this to a companion; the chat-pane variant in
          # PubSubHandlers does not apply here. Only the *primary* chat opens
          # the brain page as a companion — a companion chat is bound to a
          # brain page that is already the tab's primary, so opening a
          # companion would hijack its own slot (see `maybe_open_companion/2`).
          if socket.assigns[:role] == :primary do
            MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
              "type" => "brain_page",
              "id" => page_id
            })
          end

          socket

        _ ->
          socket
          |> maybe_open_companion(payload)
          |> PubSubHandlers.handle_agent_signal(conversation_id, payload)
      end

    {:noreply, socket}
  end

  # ModelSelectorComponent notifications — sent via notify_parent/1

  def handle_info(
        {MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent,
         {:model_selected, model_id, mode, _context}},
        socket
      ) do
    actor = socket.assigns.current_user
    conversation = socket.assigns.conversation

    persist_model_change(conversation, mode, model_id, actor)

    socket =
      case mode do
        :image_generation ->
          socket
          |> assign(:selected_model_id, model_id)
          |> assign(:selected_image_model_id, model_id)

        :video_generation ->
          socket
          |> assign(:selected_model_id, model_id)
          |> assign(:selected_video_model_id, model_id)

        _ ->
          socket
          |> assign(:selected_model_id, model_id)
          |> assign(:selected_chat_model_id, model_id)
      end

    {:noreply, socket}
  end

  def handle_info(
        {MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent,
         {:mode_changed, new_mode, selected_model_id, _context}},
        socket
      ) do
    actor = socket.assigns.current_user
    conversation = socket.assigns.conversation

    case Magus.Chat.set_conversation_mode(conversation, %{chat_mode: new_mode}, actor: actor) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    {:noreply,
     socket
     |> assign(:chat_mode, new_mode)
     |> assign(:selected_model_id, selected_model_id)}
  end

  # Tab-chrome broadcasts from TabContainer (in response to rail panel events).
  # The rail lives in a sibling LV process so it reaches us via PubSub on the
  # tab's topic.

  # `:active_prompt` and `:insert_text` are scoped to the primary chat input
  # (when the conversation is the primary view of its tab). Companion chats
  # — opened e.g. from a brain page or PDF — sit on the same tab topic but
  # must ignore these signals so they don't accidentally activate prompts
  # or insert text into the wrong textarea.
  def handle_info(
        {:workbench_chrome, {:active_prompt, prompt}},
        %{assigns: %{role: :primary}} = socket
      ) do
    {:noreply, assign(socket, :active_system_prompt, prompt)}
  end

  def handle_info({:workbench_chrome, {:active_prompt, _}}, socket), do: {:noreply, socket}

  def handle_info(
        {:workbench_chrome, {:insert_text, text}},
        %{assigns: %{role: :primary}} = socket
      ) do
    {:noreply, push_event(socket, "insert_text", %{text: text})}
  end

  def handle_info({:workbench_chrome, {:insert_text, _}}, socket), do: {:noreply, socket}

  # File-as-parent flow: a sibling FileView LV broadcasts a PDF text-selection
  # payload (text + screenshot + page + filename) on the tab topic. Stash it
  # under :pdf_selection so the next message-send picks it up, mirroring the
  # chat-as-parent handle_event("pdf:ask_about_selection", ...) flow.
  def handle_info({:workbench_chrome, {:pdf_selection, payload}}, socket) do
    {:noreply, assign(socket, :pdf_selection, payload)}
  end

  # Sibling DraftCompanion LV broadcasts a draft text-selection payload
  # (text + hint_line + draft_title) when the user clicks "Ask" in the
  # editor's bubble menu. Stash it under :draft_selection so the next
  # message-send rolls it into the metadata under "draft_selection".
  def handle_info({:workbench_chrome, {:draft_selection, payload}}, socket) do
    {:noreply, assign(socket, :draft_selection, payload)}
  end

  # Sibling BrainPageView LV broadcasts a brain text-selection payload
  # (text + page_title) on the tab topic when the user clicks "Ask" in
  # the brain editor's bubble menu. Whichever chat hosts the input on
  # this tab — primary or companion — picks it up and shows the chip.
  def handle_info({:workbench_chrome, {:brain_selection, payload}}, socket) do
    {:noreply, assign(socket, :brain_selection, payload)}
  end

  # Companion open/close events arrive on the same tab topic. They're handled
  # by TabContainer; we ignore them here.
  def handle_info({:workbench_companion, _}, socket), do: {:noreply, socket}

  # Deferred insert from a pending chat action captured during mount (see
  # `apply_pending_chat_action/2`). Firing here ensures the textarea's
  # `ChatTextarea` JS hook is already mounted and listening.
  def handle_info({:apply_pending_insert_text, text}, socket) when is_binary(text) do
    {:noreply, push_event(socket, "insert_text", %{text: text, mode: "replace"})}
  end

  # ============================================================================
  # notify_parent messages from rail-panel components.
  #
  # The "Panels" popover (RightRail) is mounted as a LiveComponent inside this
  # LV's chat header, so notify_parent calls from its nested panel components
  # (LibrarySidebar / DraftsSidebar / BrainSidebar) land here.
  # ============================================================================

  def handle_info({LibrarySidebarComponent, {:activate_system_prompt, prompt}}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    socket =
      with true <- not is_nil(conv),
           {:ok, _updated} <- Magus.Chat.activate_system_prompt(conv, prompt.id, actor: user) do
        loaded_prompt = Ash.load!(prompt, [:model], actor: user)
        Signals.broadcast_active_prompt(socket.assigns.tab_id, loaded_prompt)
        invalidate_rail_panel_data(socket)
        assign(socket, :active_system_prompt, loaded_prompt)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info({LibrarySidebarComponent, :deactivate_system_prompt}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    socket =
      with true <- not is_nil(conv),
           {:ok, _updated} <- Magus.Chat.deactivate_system_prompt(conv, actor: user) do
        Signals.broadcast_active_prompt(socket.assigns.tab_id, nil)
        invalidate_rail_panel_data(socket)
        assign(socket, :active_system_prompt, nil)
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info({LibrarySidebarComponent, {:insert_prompt_content, prompt}}, socket) do
    if text = prompt && prompt.content do
      Signals.broadcast_insert_text(socket.assigns.tab_id, text)
    end

    {:noreply, socket}
  end

  def handle_info({DraftsSidebarComponent, {:switch_draft, draft_id}}, socket) do
    Signals.broadcast_open_companion(socket.assigns.tab_id, %{
      "type" => "draft",
      "id" => draft_id
    })

    {:noreply, socket}
  end

  def handle_info({DraftsSidebarComponent, {:delete_draft, draft_id}}, socket) do
    user = socket.assigns.current_user

    case Magus.Drafts.get_draft(draft_id, actor: user) do
      {:ok, draft} ->
        Magus.Drafts.destroy_draft(draft, actor: user)
        invalidate_rail_panel_data(socket)

      _ ->
        :noop
    end

    {:noreply, socket}
  end

  def handle_info({BrainSidebarComponent, {:open_brain_page, _brain_id, page_id}}, socket) do
    Signals.broadcast_open_companion(socket.assigns.tab_id, %{
      "type" => "brain_page",
      "id" => page_id
    })

    {:noreply, socket}
  end

  def handle_info({BrainSidebarComponent, {:brain_deleted, _brain_id}}, socket) do
    invalidate_rail_panel_data(socket)
    {:noreply, socket}
  end

  # Deferred panel signals: the legacy sidebar components emit these to open
  # modals/forms that aren't hosted in the workbench shell yet. Match
  # explicitly so they leave a breadcrumb when invoked.
  @deferred_library_signals [:create_brain, :hide_prompt_form, :close_prompt_detail]

  def handle_info({LibrarySidebarComponent, signal}, socket)
      when signal in @deferred_library_signals do
    Logger.debug("[workbench] deferred LibrarySidebarComponent signal: #{inspect(signal)}")
    {:noreply, socket}
  end

  def handle_info({LibrarySidebarComponent, {tag, _payload}}, socket)
      when tag in [:show_prompt_form, :view_prompt_detail, :create_prompt_from_conversation] do
    Logger.debug("[workbench] deferred LibrarySidebarComponent signal: #{inspect(tag)}")
    {:noreply, socket}
  end

  def handle_info({BrainSidebarComponent, signal}, socket)
      when signal == :create_brain do
    Logger.debug("[workbench] deferred BrainSidebarComponent signal: #{inspect(signal)}")
    {:noreply, socket}
  end

  def handle_info({BrainSidebarComponent, {tag, _}}, socket)
      when tag in [:create_page_in_brain] do
    Logger.debug("[workbench] deferred BrainSidebarComponent signal: #{inspect(tag)}")
    {:noreply, socket}
  end

  def handle_info({BrainSidebarComponent, {tag, _, _}}, socket)
      when tag in [:create_page_in_brain] do
    Logger.debug("[workbench] deferred BrainSidebarComponent signal: #{inspect(tag)}")
    {:noreply, socket}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp invalidate_rail_panel_data(%{assigns: %{conversation: %{id: conv_id}}} = _socket) do
    send_update(RightRail, id: "right-rail-#{conv_id}", panel_data_dirty?: true)
  end

  defp invalidate_rail_panel_data(_socket), do: :noop

  # Builds the message metadata map, merging in pdf_selection (text + screenshot
  # + page + filename) when one is stashed via the companion :pdf_selection
  # broadcast. Mirrors the legacy chat-as-parent flow so the LLM context
  # builder sees the same shape regardless of which side hosts the PDF viewer.
  defp build_message_metadata(nil), do: %{}

  defp build_message_metadata(%{} = selection) do
    %{
      "pdf_selection" => %{
        "image" => Map.get(selection, :image) || Map.get(selection, "image"),
        "text" => Map.get(selection, :text) || Map.get(selection, "text"),
        "page" => Map.get(selection, :page) || Map.get(selection, "page"),
        "filename" => Map.get(selection, :filename) || Map.get(selection, "filename")
      }
    }
  end

  # Append message_selections (Ask Chat highlights from the message stream)
  # under the same `"message_selections"` key the legacy chat used, so the
  # downstream context builders don't need to learn a new shape.
  defp attach_message_selections(metadata, selections) when selections in [nil, []], do: metadata

  defp attach_message_selections(metadata, selections) when is_list(selections) do
    Map.put(
      metadata,
      "message_selections",
      Enum.map(selections, fn s ->
        %{"text" => s.text, "message_id" => s.message_id, "role" => s.role}
      end)
    )
  end

  # Append a draft_selection (from the draft pane bubble menu's "Ask" button)
  # under `"draft_selection"`, same shape the legacy chat builder consumes.
  # The map keys are already strings since they come in over PubSub.
  defp attach_draft_selection(metadata, nil), do: metadata

  defp attach_draft_selection(metadata, %{} = selection) do
    Map.put(metadata, "draft_selection", %{
      "text" => Map.get(selection, "text") || Map.get(selection, :text) || "",
      "hint_line" => Map.get(selection, "hint_line") || Map.get(selection, :hint_line),
      "draft_title" => Map.get(selection, "draft_title") || Map.get(selection, :draft_title)
    })
  end

  # When a primary brain page opens a chat companion via "Ask", it embeds
  # the selection in the companion-open spec; `TabContainer` threads it
  # into our mount session under "initial_brain_selection". Normalize to
  # the same shape `chat_input_component.brain_selection_badge` consumes
  # (string keys "text", "page_title").
  defp normalize_initial_brain_selection(%{"initial_brain_selection" => selection})
       when is_map(selection) do
    %{
      "text" => Map.get(selection, "text") || Map.get(selection, :text) || "",
      "page_title" => Map.get(selection, "page_title") || Map.get(selection, :page_title)
    }
  end

  defp normalize_initial_brain_selection(_), do: nil

  # Sends a user message in the current conversation. Shared between the
  # chat-input flow (regular send) and action_card_click "send_message"
  # so they can't drift on mode/model/metadata. `overrides` may carry
  # `:mode`, `:selected_model_id`, `:uploaded_resources`, `:metadata`;
  # missing keys fall back to the conversation's current chat_mode and
  # selected_model_id.
  defp send_user_message_action(socket, text, overrides) do
    {params, _resources, _metadata} = build_user_message_params(socket, text, overrides)

    Magus.Chat.send_user_message(params, actor: socket.assigns.current_user)
  end

  # Queue path counterpart to `send_user_message_action/3`. Reuses the same
  # resource/metadata building so a queued message carries identical context;
  # `enqueue_message` takes `conversation_id` positionally and `resources` as
  # an action argument (not part of the params map).
  defp enqueue_user_message_action(socket, text, overrides) do
    {params, resources, _metadata} = build_user_message_params(socket, text, overrides)

    enqueue_params =
      params
      |> Map.drop([:conversation_id])
      |> Map.put(:resources, resources)

    Magus.Chat.enqueue_message(
      socket.assigns.conversation.id,
      enqueue_params,
      actor: socket.assigns.current_user
    )
  end

  # Shared param/resource/metadata building for both the send and enqueue paths.
  defp build_user_message_params(socket, text, overrides) do
    uploaded = Map.get(overrides, :uploaded_resources, [])
    all_resources = (socket.assigns[:context_resources] || []) ++ uploaded

    metadata =
      socket.assigns[:pdf_selection]
      |> build_message_metadata()
      |> attach_message_selections(socket.assigns[:message_selections])
      |> attach_draft_selection(socket.assigns[:draft_selection])
      |> Map.merge(Map.get(overrides, :metadata, %{}))

    params = %{
      text: text,
      mode: Map.get(overrides, :mode) || socket.assigns[:chat_mode] || :chat,
      selected_model_id:
        Map.get(overrides, :selected_model_id) || socket.assigns[:selected_model_id],
      conversation_id: socket.assigns.conversation.id,
      resources: all_resources,
      metadata: metadata
    }

    {params, all_resources, metadata}
  end

  defp handle_send_now(socket, text, params, uploaded_resources) do
    result =
      send_user_message_action(socket, text, %{
        mode: Helpers.parse_mode(params["mode"]),
        selected_model_id: params["selected_model_id"],
        uploaded_resources: uploaded_resources
      })

    case result do
      {:ok, message} ->
        textarea_id = "conv-#{socket.assigns.conversation.id}-chat-textarea"

        {:noreply,
         socket
         |> assign(
           :message_form,
           build_message_form(socket.assigns.conversation, socket.assigns.current_user)
         )
         |> assign(:context_resources, [])
         |> assign(:pdf_selection, nil)
         |> assign(:draft_selection, nil)
         |> assign(:brain_selection, nil)
         |> assign(:message_selections, [])
         |> assign(:waiting_for_response, true)
         |> assign(:agent_busy?, true)
         |> assign(:thinking_status, :thinking)
         |> stream_insert(:messages, message, at: 0)
         |> push_event("clear_message_input", %{target: textarea_id})
         |> push_event("scroll_to_bottom", %{force: true})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not send message. Please try again.")}
    end
  end

  # Queue the message (no agent dispatch) and clear the composer. The queued
  # region updates via the `enqueue_message` PubSub broadcast.
  defp handle_enqueue_while_running(socket, text, params, uploaded_resources) do
    result =
      enqueue_user_message_action(socket, text, %{
        mode: Helpers.parse_mode(params["mode"]),
        selected_model_id: params["selected_model_id"],
        uploaded_resources: uploaded_resources
      })

    case result do
      {:ok, _message} ->
        textarea_id = "conv-#{socket.assigns.conversation.id}-chat-textarea"

        {:noreply,
         socket
         |> assign(
           :message_form,
           build_message_form(socket.assigns.conversation, socket.assigns.current_user)
         )
         |> assign(:context_resources, [])
         |> assign(:pdf_selection, nil)
         |> assign(:draft_selection, nil)
         |> assign(:brain_selection, nil)
         |> assign(:message_selections, [])
         |> push_event("clear_message_input", %{target: textarea_id})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not queue message. Please try again.")}
    end
  end

  defp agent_running?(socket) do
    Map.get(socket.assigns, :waiting_for_response, false) or
      Map.get(socket.assigns, :is_streaming, false)
  end

  # Whole-turn busy flag. Unlike `agent_running?` (phase-level: only true while
  # waiting_for_response or is_streaming), this latches for the entire turn:
  # set on dispatch and on every turn signal (text/thinking chunk, tool.start),
  # cleared only on the terminal reset (response.complete / error / cancel). It
  # closes the inter-tool gap where both phase flags read false mid-turn.
  defp agent_busy?(socket), do: Map.get(socket.assigns, :agent_busy?, false)

  # Reads the id from a queued-message payload. PubSub transforms emit atom keys,
  # but loaded queue rows are %Message{} structs; both expose `.id`. Defensive
  # against string-keyed maps too.
  defp queued_message_id(%{id: id}), do: id
  defp queued_message_id(%{"id" => id}), do: id
  defp queued_message_id(_), do: nil

  # `write_draft` auto-open is driven by the `draft.created` PubSub event
  # rather than `tool.complete`, because the tool.complete payload does not
  # carry the draft id. See the Broadcast handler for `drafts:conversation:`.

  # Workbench-specific UI side effects on tool completion. Runs in addition to
  # the canonical state update from PubSubHandlers.handle_agent_signal.
  defp maybe_open_companion(socket, %{type: "tool.complete", tool_name: "start_service"}) do
    MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
      "type" => "service",
      "id" => socket.assigns.conversation.id
    })

    socket
  end

  # Only fires for the *primary* chat. When this conversation is itself a
  # companion (role: :companion), it is the chat companion of a brain page
  # that already occupies the tab's primary slot — so the agent's
  # navigate/edit lands on the page that's already open. Broadcasting
  # open_companion here would replace the chat (the tab has a single
  # companion slot) with a duplicate of the primary page. The primary
  # BrainPageView refreshes itself via its own page PubSub subscription, so
  # the companion chat does nothing. Mirrors the avoid-nesting rule in
  # `BrainPageView.handle_open_brain_file/5`.
  defp maybe_open_companion(
         %{assigns: %{role: :primary}} = socket,
         %{type: "tool.complete", tool_name: tool_name} = payload
       )
       when tool_name in ["read_brain", "edit_brain", "navigate_brain"] do
    if page_id = extract_brain_page_id(payload) do
      MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
        "type" => "brain_page",
        "id" => page_id
      })
    end

    socket
  end

  defp maybe_open_companion(socket, _payload), do: socket

  @impl true
  # Drain the whole queue: each flushed message broadcasts `flush_queued` on
  # `chat:queued:*` (drops it from the region) and `messages` (renders the bubble).
  def handle_event("send_now_queued", _params, socket) do
    Magus.Chat.send_now_queued(socket.assigns.conversation.id, actor: socket.assigns.current_user)
    {:noreply, socket}
  end

  # Remove a single queued message before delivery. The `remove_queued`
  # broadcast on `chat:queued:*` updates `@queued_messages`.
  def handle_event("remove_queued", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    with {:ok, msg} <- Magus.Chat.get_message(id, actor: user) do
      _ = Magus.Chat.remove_queued_message(msg, actor: user)
    end

    {:noreply, socket}
  end

  def handle_event("load_older_messages", _params, socket) do
    %{
      conversation: conv,
      current_user: user,
      oldest_message_at: cursor,
      has_more_messages?: has_more?,
      loading_older_messages?: loading?
    } = socket.assigns

    cond do
      not has_more? or loading? or is_nil(conv) or is_nil(cursor) ->
        {:noreply, socket}

      true ->
        socket = assign(socket, :loading_older_messages?, true)

        %{messages: older, oldest_at: new_oldest_at, has_more?: still_more?} =
          load_messages(conv, user, before: cursor)

        # `at: -1` appends to DOM end. Under flex-col-reverse that places each
        # appended message at the visual TOP. Iterating the DESC-sorted batch
        # in order yields the correct visual order (next-older just above the
        # previously-oldest, much-older above that).
        socket =
          Enum.reduce(older, socket, fn msg, acc ->
            stream_insert(acc, :messages, msg, at: -1)
          end)

        {:noreply,
         socket
         |> assign(:oldest_message_at, new_oldest_at || cursor)
         |> assign(:has_more_messages?, still_more?)
         |> assign(:loading_older_messages?, false)
         |> Helpers.assign_floor_boundary()
         |> push_event("older_messages_loaded", %{count: length(older)})}
    end
  end

  def handle_event("toggle_favorite_conversation", _params, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    case Magus.Chat.get_conversation_favorite(conv.id, actor: user) do
      {:ok, fav} -> Magus.Chat.destroy_conversation_favorite!(fav, actor: user)
      _ -> Magus.Chat.create_conversation_favorite!(%{conversation_id: conv.id}, actor: user)
    end

    Signals.broadcast_favorites_changed(user.id)

    {:noreply, assign(socket, :is_favorited, !socket.assigns.is_favorited)}
  end

  def handle_event("share_to_workspace", _params, socket) do
    {:noreply, toggle_conversation_share(socket, :share)}
  end

  def handle_event("unshare_from_workspace", _params, socket) do
    {:noreply, toggle_conversation_share(socket, :unshare)}
  end

  def handle_event("open_share_modal", _params, socket) do
    share_links =
      load_active_share_links(socket.assigns.conversation, socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(:share_links, share_links)
     |> assign(:has_active_share_links, share_links != [])
     |> assign(:show_share_modal, true)}
  end

  def handle_event("close_share_modal", _params, socket) do
    {:noreply, assign(socket, :show_share_modal, false)}
  end

  def handle_event("start_edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title?, true)}
  end

  def handle_event("cancel_edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title?, false)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    case Magus.Chat.rename_conversation(conv, %{title: title}, actor: user) do
      {:ok, updated} ->
        # Only `title` changed — updating that one field preserves the
        # loaded relationships (custom_agent, message_count, last_message_at,
        # selected_model) that were populated at mount.
        {:noreply,
         socket
         |> assign(:conversation, %{conv | title: updated.title})
         |> assign(:editing_title?, false)}

      {:error, _} ->
        {:noreply, assign(socket, :editing_title?, false)}
    end
  end

  # Drag-and-drop from rail panels: the global JS `DropZone` hook
  # (assets/js/app.js) parses dropped JSON and pushes one of these events to
  # the LV that contains the hook element. We mount that hook on this view's
  # wrapper, so the events land here.

  def handle_event("activate_system_prompt_by_id", %{"prompt_id" => prompt_id}, socket) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    if conv do
      case Magus.Library.get_prompt(prompt_id, actor: user, load: [:model]) do
        {:ok, prompt} ->
          case Magus.Chat.activate_system_prompt(conv, prompt.id, actor: user) do
            {:ok, _} -> {:noreply, assign(socket, :active_system_prompt, prompt)}
            _ -> {:noreply, socket}
          end

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("insert_prompt_content", %{"prompt_id" => prompt_id}, socket) do
    user = socket.assigns.current_user

    case Magus.Library.get_prompt(prompt_id, actor: user) do
      {:ok, %{content: text}} when is_binary(text) ->
        {:noreply, push_event(socket, "insert_text", %{text: text})}

      _ ->
        {:noreply, socket}
    end
  end

  # Legacy `add_resource_to_context` was emitted by an older Memory sidebar
  # that no longer ships in the workbench. Files now drag in via the
  # dedicated `DraggableFile` hook, which dispatches `add_file_to_context`
  # below. Keep the no-op clause so any stale clients can't crash the LV.
  def handle_event("add_resource_to_context", _params, socket), do: {:noreply, socket}

  # "Ask Chat" popup on a text selection inside a message bubble. The
  # `MessageTextSelection` JS hook tracks selection inside any message-text
  # element and pushes this event with the trimmed selection plus its
  # source message_id and role so the chip can show "your message" vs
  # "agent message". Selections are merged into the next outgoing message's
  # metadata (see `attach_message_selections/2`) and cleared on send.
  def handle_event("ask_about_message_selection", params, socket) do
    existing = socket.assigns[:message_selections] || []
    text = String.slice(params["text"] || "", 0, 5_000)

    selection = %{
      text: text,
      message_id: params["message_id"],
      role: params["role"] || "agent"
    }

    cond do
      length(existing) >= 20 ->
        {:noreply, socket}

      Enum.any?(existing, &(&1.message_id == selection.message_id and &1.text == selection.text)) ->
        {:noreply, socket}

      true ->
        {:noreply, assign(socket, :message_selections, existing ++ [selection])}
    end
  end

  def handle_event("clear_draft_selection", _params, socket) do
    {:noreply, assign(socket, :draft_selection, nil)}
  end

  # `chat_input_component.brain_selection_badge` X button fires this
  # legacy-named event; mirrors `brain_text_cleared` in the legacy ChatLive.
  def handle_event("brain_text_cleared", _params, socket) do
    {:noreply, assign(socket, :brain_selection, nil)}
  end

  # Phase C5: "Add to brain" message buttons append a markdown wikilink
  # (`[[msg:<id>|<preview>]]`) to the body of the brain page currently
  # open in this tab's brain pane. Silent no-op when no brain pane is
  # open (the buttons only render when `@brain_pane_page_id` is set, but
  # a stale client click could still arrive).
  def handle_event(
        "add_message_to_brain",
        %{"message-id" => message_id, "text" => preview} = _params,
        socket
      ) do
    {:noreply, do_append_message_to_brain(socket, message_id, preview)}
  end

  # "Add source" message-button: append a ```source fence with the
  # citation URL and (optional) title. Same no-op semantics as above
  # when no brain pane is open or the URL is blank.
  def handle_event(
        "add_source_from_message",
        %{"url" => url} = params,
        socket
      ) do
    title = Map.get(params, "title")
    {:noreply, do_append_source_to_brain(socket, url, title)}
  end

  def handle_event("clear_message_selection", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    selections = socket.assigns[:message_selections] || []

    if idx >= 0 and idx < length(selections) do
      {:noreply, assign(socket, :message_selections, List.delete_at(selections, idx))}
    else
      {:noreply, socket}
    end
  end

  # File dragged from the Files sidebar / quick access into the conversation.
  # We load the file with the user as actor (which enforces the same access
  # checks as the rest of the chat input) and append it to
  # `:context_resources` so it rides along on the next message. Dedupe by
  # id so a re-drop is a no-op rather than producing a duplicate chip.
  def handle_event("add_file_to_context", %{"file_id" => file_id}, socket) do
    user = socket.assigns.current_user
    current = socket.assigns[:context_resources] || []

    cond do
      Enum.any?(current, &(&1.id == file_id)) ->
        {:noreply, socket}

      true ->
        case Magus.Files.get_file(file_id, actor: user) do
          {:ok, file} ->
            {:noreply, assign(socket, :context_resources, current ++ [file])}

          _ ->
            {:noreply, socket}
        end
    end
  end

  def handle_event("remove_context_resource", %{"id" => file_id}, socket) do
    current = socket.assigns[:context_resources] || []
    {:noreply, assign(socket, :context_resources, Enum.reject(current, &(&1.id == file_id)))}
  end

  def handle_event("close_companion", _params, socket) do
    if socket.assigns[:tab_id] do
      MagusWeb.Workbench.Signals.broadcast_close_companion(socket.assigns.tab_id)
    end

    {:noreply, socket}
  end

  def handle_event("open_service_pane", _params, socket) do
    MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
      "type" => "service",
      "id" => socket.assigns.conversation.id
    })

    {:noreply, socket}
  end

  def handle_event("open_draft_pane", params, socket) do
    draft_id = params["draft-id"] || params["draft_id"]

    if draft_id do
      MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
        "type" => "draft",
        "id" => draft_id
      })
    end

    {:noreply, socket}
  end

  def handle_event("open_thread", %{"thread-id" => thread_id}, socket) do
    open_thread_companion(thread_id, socket)
  end

  def handle_event("open_thread_from_sidebar", %{"thread-id" => thread_id}, socket) do
    open_thread_companion(thread_id, socket)
  end

  def handle_event("start_thread", %{"message-id" => message_id}, socket) do
    current_user = socket.assigns.current_user
    conversation = socket.assigns.conversation

    existing_threads =
      Magus.Chat.threads_for_conversation!(conversation.id, actor: current_user)

    thread_id =
      case Enum.find(existing_threads, &(to_string(&1.branched_at_message_id) == message_id)) do
        %{id: id} ->
          id

        nil ->
          case Magus.Chat.create_thread(
                 %{
                   parent_conversation_id: conversation.id,
                   branched_at_message_id: message_id
                 },
                 actor: current_user
               ) do
            {:ok, thread} -> thread.id
            {:error, _} -> nil
          end
      end

    if thread_id do
      MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
        "type" => "thread",
        "id" => thread_id
      })
    end

    {:noreply, socket}
  end

  def handle_event("open_pdf_pane", params, socket) do
    file_id = params["file-id"]
    filename = params["name"]
    url = params["url"]

    if file_id && url do
      MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
        "type" => "pdf",
        "id" => file_id,
        "name" => filename || file_id,
        "url" => url
      })
    end

    {:noreply, socket}
  end

  def handle_event("open_spreadsheet_pane", params, socket) do
    file_id = params["file-id"]
    filename = params["name"]

    if file_id do
      MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
        "type" => "spreadsheet",
        "id" => file_id,
        "name" => filename || file_id
      })
    end

    {:noreply, socket}
  end

  def handle_event("open_thread_from_message", %{"message-id" => message_id}, socket) do
    current_user = socket.assigns.current_user
    conversation = socket.assigns.conversation

    threads = Magus.Chat.threads_for_conversation!(conversation.id, actor: current_user)

    case Enum.find(threads, &(to_string(&1.branched_at_message_id) == message_id)) do
      nil ->
        {:noreply, socket}

      thread ->
        MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
          "type" => "thread",
          "id" => thread.id
        })

        {:noreply, socket}
    end
  end

  def handle_event(
        "action_card_click",
        %{"type" => "send_message", "payload" => payload},
        socket
      ) do
    if is_nil(socket.assigns[:conversation]) do
      {:noreply, socket}
    else
      case send_user_message_action(socket, payload, %{
             metadata: %{"action_card" => true}
           }) do
        {:ok, message} ->
          {:noreply,
           socket
           |> assign(:waiting_for_response, true)
           |> assign(:agent_busy?, true)
           |> assign(:thinking_status, :thinking)
           |> stream_insert(:messages, message, at: 0)
           |> push_event("scroll_to_bottom", %{force: true})}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not send message. Please try again.")}
      end
    end
  end

  def handle_event("action_card_click", %{"type" => "prefill", "payload" => payload}, socket) do
    {:noreply, push_event(socket, "insert_text", %{text: payload, mode: "replace"})}
  end

  def handle_event("action_card_click", _params, socket), do: {:noreply, socket}

  def handle_event("stop_response", _params, socket) do
    conversation = socket.assigns[:conversation]

    if conversation do
      if triggering_id = socket.assigns[:triggering_message_id] do
        Helpers.cancel_oban_job_for_message(triggering_id)
      end

      case Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{conversation.id}") do
        {:ok, pid} ->
          signal = Jido.Signal.new!("message.cancel", %{conversation_id: conversation.id})
          Jido.AgentServer.cast(pid, signal)

        :error ->
          :ok
      end

      Magus.Chat.create_event_message!(
        gettext("Response cancelled"),
        conversation.id,
        authorize?: false
      )
    end

    {:noreply,
     socket
     |> assign(:waiting_for_response, false)
     |> assign(:is_streaming, false)
     |> assign(:agent_busy?, false)
     |> assign(:active_response_ids, MapSet.new())
     |> assign(:streaming_initialized_ids, MapSet.new())
     |> assign(:pending_mention_count, 0)
     |> assign(:current_response_message_id, nil)
     |> assign(:triggering_message_id, nil)}
  end

  # Startpage "Your open tasks" affordances. `complete` marks the task done;
  # `dismiss` hides it from this user's startpage only (the task stays open in
  # its conversation's task pane). Both drop the row from @user_open_tasks.
  def handle_event("complete_open_task", %{"id" => id}, socket),
    do: act_on_open_task(socket, id, &Magus.Plan.complete_task/2)

  def handle_event("dismiss_open_task", %{"id" => id}, socket),
    do: act_on_open_task(socket, id, &Magus.Plan.dismiss_task/2)

  # Context-window controls (donut panel). These arrive as plain (non-targeted)
  # phx-click events from the nested ContextIndicatorComponent and bubble up here.
  # The control row only renders for the owner (ContextIndicatorComponent gates
  # it on is_owner), and the underlying Magus.Chat actions are owner-gated by the
  # ContextWindow policies. These handlers are defensive belt-and-suspenders: a
  # forged event from a non-owner returns {:error, Forbidden} (no-op), and a nil
  # conversation (new-chat composer) is short-circuited before touching conv.id.
  def handle_event("clear_context", _params, socket) do
    {:noreply, run_context_op(socket, &Magus.Chat.clear_context_for_conversation/2)}
  end

  def handle_event("set_context_strategy", %{"strategy" => s}, socket)
      when s in ["rolling", "compact"] do
    clicked = String.to_existing_atom(s)

    # Toggle off: re-clicking the conversation's CURRENT explicit override clears
    # it back to nil (inherit the app default), mirroring the SPA. The persisted
    # override is the context-window `strategy` (nil when inheriting); clicking a
    # different strategy sets that explicit value instead.
    current = current_strategy_override(socket)
    strategy = if clicked == current, do: nil, else: clicked

    op = fn conversation_id, opts ->
      Magus.Chat.set_context_strategy_for_conversation(conversation_id, strategy, opts)
    end

    {:noreply, run_context_op(socket, op)}
  end

  # Request a compaction pass. The owner-gated :request_compaction action sets
  # the window to :pending and (via an after_action) enqueues the Oban
  # compaction trigger. The donut + Send button lock immediately off the
  # returned :pending status; the `context.updated` broadcast emitted by
  # RunCompaction on completion refreshes the donut and re-enables Send.
  def handle_event("compact_context", _params, socket) do
    {:noreply, run_context_op(socket, &Magus.Chat.compact_context_for_conversation/2)}
  end

  def handle_event(_unhandled, _params, socket), do: {:noreply, socket}

  # Runs an owner-gated context-window op for the current conversation and
  # assigns the refreshed window. Defensive on two fronts:
  #   - nil conversation (new-chat composer): no-op, return the socket unchanged
  #     (guards against a BadMapError on conv.id).
  #   - {:error, _} (e.g. a non-owner's forged event hits the owner-only policy
  #     and returns Forbidden): no-op, leave the window assign untouched (guards
  #     against a MatchError that would crash the LiveView).
  # `op` is a 2-arity fun: (conversation_id, opts) -> {:ok, window} | {:error, _}.
  # The conversation's CURRENT explicit strategy override, or nil when inheriting
  # the app default. Read from the persisted context-window snapshot in the
  # assigns; nil-safe so a missing window reads as "no override".
  defp current_strategy_override(socket) do
    case socket.assigns[:context_window] do
      %{strategy: strategy} -> strategy
      _ -> nil
    end
  end

  defp run_context_op(%{assigns: %{conversation: nil}} = socket, _op), do: socket

  defp run_context_op(socket, op) do
    conv = socket.assigns.conversation
    user = socket.assigns.current_user

    case op.(conv.id, actor: user) do
      {:ok, cw} -> assign(socket, :context_window, cw)
      {:error, _} -> socket
    end
  end

  # Acts on a task already present in @user_open_tasks (so we only touch tasks
  # shown to this user); the resource policy still authorizes via the actor.
  defp act_on_open_task(socket, id, fun) do
    user = socket.assigns.current_user
    tasks = socket.assigns.user_open_tasks || []

    with %{} = task <- Enum.find(tasks, &(to_string(&1.id) == id)),
         {:ok, _} <- fun.(task, actor: user) do
      {:noreply, assign(socket, :user_open_tasks, Enum.reject(tasks, &(&1.id == task.id)))}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:conversation] do
      %{id: id} -> Phoenix.PubSub.unsubscribe(Magus.PubSub, "agents:#{id}")
      _ -> :ok
    end

    :ok
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  # Phase C5: "Add to brain" message buttons append markdown directly to
  # the open brain pane page's body. `BodyAppender` handles markdown
  # rendering and the single-retry VersionConflict protocol; the caller
  # here is only responsible for loading the page (so it carries the
  # current `lock_version`) and surfacing UX flashes on failure.

  defp do_append_message_to_brain(socket, message_id, preview)
       when is_binary(message_id) and message_id != "" do
    with_open_brain_page(socket, fn page, user ->
      Magus.Brain.BodyAppender.append_message(
        page,
        %{message_id: message_id, preview: preview},
        user
      )
    end)
  end

  defp do_append_message_to_brain(socket, _message_id, _preview), do: socket

  defp do_append_source_to_brain(socket, url, title) when is_binary(url) and url != "" do
    with_open_brain_page(socket, fn page, user ->
      Magus.Brain.BodyAppender.append_source(
        page,
        %{url: url, title: title, source_type: "web"},
        user
      )
    end)
  end

  defp do_append_source_to_brain(socket, _url, _title), do: socket

  defp with_open_brain_page(socket, fun) do
    page_id = socket.assigns[:brain_pane_page_id]
    user = socket.assigns[:current_user]

    cond do
      is_nil(page_id) ->
        socket

      is_nil(user) ->
        socket

      true ->
        case Magus.Brain.get_page(page_id, actor: user) do
          {:ok, page} ->
            case fun.(page, user) do
              {:ok, _updated} ->
                socket

              {:error, :empty} ->
                socket

              {:error, _reason} ->
                put_flash(socket, :error, gettext("Couldn't add to brain. Please try again."))
            end

          {:error, _} ->
            socket
        end
    end
  end

  defp persist_model_change(conversation, :chat, model_id, actor) do
    Magus.Chat.set_conversation_model(conversation, %{selected_model_id: model_id}, actor: actor)
  end

  defp persist_model_change(conversation, :image_generation, model_id, actor) do
    Magus.Chat.set_conversation_image_model(
      conversation,
      %{selected_image_model_id: model_id},
      actor: actor
    )
  end

  defp persist_model_change(conversation, :video_generation, model_id, actor) do
    Magus.Chat.set_conversation_video_model(
      conversation,
      %{selected_video_model_id: model_id},
      actor: actor
    )
  end

  defp persist_model_change(_conversation, _mode, _model_id, _actor), do: :ok

  defp load_active_share_links(%{id: id}, user) do
    case Magus.Chat.get_active_share_links(id, actor: user) do
      {:ok, links} -> links
      _ -> []
    end
  end

  defp toggle_conversation_share(socket, action) do
    user = socket.assigns.current_user
    conv = socket.assigns.conversation

    result =
      case action do
        :share -> WorkspaceShare.share(:conversation, conv, user)
        :unshare -> WorkspaceShare.unshare(:conversation, conv, user)
      end

    case result do
      {:ok, _} -> refresh_conversation_share(socket, conv, user)
      :no_workspace -> socket
      {:error, _} -> put_flash(socket, :error, conversation_share_error(action))
    end
  end

  defp refresh_conversation_share(socket, conv, user) do
    case Magus.Chat.get_conversation(conv.id,
           actor: user,
           load: [:is_collaborative, :is_shared_to_workspace]
         ) do
      {:ok, fresh} ->
        assign(socket, :conversation, %{
          conv
          | is_collaborative: fresh.is_collaborative,
            is_shared_to_workspace: fresh.is_shared_to_workspace
        })

      _ ->
        socket
    end
  end

  defp conversation_share_error(:share), do: "Couldn't share this conversation."
  defp conversation_share_error(:unshare), do: "Couldn't unshare this conversation."

  @message_page_size 25

  # Default: load the most recent @message_page_size messages, newest-first
  # (DESC). With the message stream's flex-col-reverse layout, that DOM order
  # renders visually as oldest-at-top / newest-at-bottom.
  #
  # Opts:
  #   * `:before` — `%DateTime{}` cursor. Loads messages older than this for
  #     scroll-up pagination.
  defp load_messages(conversation, current_user, opts \\ []) do
    require Ash.Query
    before_cursor = Keyword.get(opts, :before)

    query =
      Magus.Chat.Message
      |> Ash.Query.for_read(:for_conversation, %{conversation_id: conversation.id},
        actor: current_user
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@message_page_size)
      |> Ash.Query.load(Helpers.message_stream_load(conversation))

    query =
      case before_cursor do
        nil -> query
        %DateTime{} = cursor -> Ash.Query.filter(query, inserted_at < ^cursor)
      end

    messages = Ash.read!(query)

    %{
      messages: messages,
      oldest_at: oldest_inserted_at(messages),
      has_more?: length(messages) >= @message_page_size
    }
  end

  defp oldest_inserted_at([]), do: nil
  # Messages arrive sorted inserted_at: :desc, so the last item is the oldest.
  defp oldest_inserted_at(messages), do: List.last(messages).inserted_at

  defp resolved_conversation_id(%{new_chat?: true}), do: "new"
  defp resolved_conversation_id(%{not_found: true, conversation_id: id}), do: id
  defp resolved_conversation_id(%{conversation: %{id: id}}), do: id

  # Pulls the custom agent (if any) out of a one-shot pending chat action so
  # mount can seed `chat_mode` and `selected_*_model_id` from agent presets
  # in a single pass through `init_chat_input_assigns/4` instead of letting
  # those defaults set then immediately overwriting them.
  defp pending_agent({:set_custom_agent, agent}), do: agent
  defp pending_agent(_), do: nil

  defp load_new_chat_features(user) do
    undiscovered = Magus.FeatureUsage.undiscovered_features(user.id)
    first_time? = length(undiscovered) == length(Magus.FeatureUsage.onboarding_feature_keys())
    %{undiscovered: undiscovered, first_time?: first_time?}
  end

  defp load_open_tasks(user) do
    case Magus.Plan.open_tasks_for_user(user.id, actor: user) do
      {:ok, tasks} -> Ash.load!(tasks, [:conversation], actor: user)
      _ -> []
    end
  end

  # Applies the *post-init* effects of a pending chat action: activating a
  # system prompt or pushing initial text into the chat input. Agent setup
  # happens earlier (see mount) since it influences `chat_mode` and model
  # selection, which are baked into `init_chat_input_assigns/4`.
  #
  # For `:insert_text` we cannot push the event during mount: the textarea's
  # `ChatTextarea` JS hook hasn't mounted yet, so the event is dispatched
  # before any listener exists and the text is silently dropped. Defer to
  # `handle_info(:apply_pending_insert_text, ...)` instead, which fires once
  # mount returns and the DOM (and hooks) are live.
  defp apply_pending_chat_action(socket, nil), do: socket
  defp apply_pending_chat_action(socket, {:set_custom_agent, _agent}), do: socket

  defp apply_pending_chat_action(socket, {:activate_system_prompt, prompt}) do
    assign(socket, :active_system_prompt, prompt)
  end

  defp apply_pending_chat_action(socket, {:insert_text, text}) when is_binary(text) do
    if connected?(socket), do: send(self(), {:apply_pending_insert_text, text})
    socket
  end

  # Skeleton chat-input assigns for the disconnected (static) render: same keys
  # as init_chat_input_assigns/4 but with no DB reads. The model catalog and
  # usage state is filled in once by init_chat_input_assigns/4 in the
  # connected? branch. Usage defaults mirror the "exempt" shape so the input is
  # not falsely disabled before the real limits load.
  defp assign_chat_input_defaults(socket, chat_mode) do
    socket
    |> assign(:chat_models, [])
    |> assign(:image_models, [])
    |> assign(:video_models, [])
    |> assign(:selected_model_id, nil)
    |> assign(:selected_chat_model_id, nil)
    |> assign(:selected_image_model_id, nil)
    |> assign(:selected_video_model_id, nil)
    |> assign(:chat_mode, chat_mode)
    |> assign(:context_resources, [])
    |> assign(:image_generation_settings, %{})
    |> assign(:video_generation_settings, %{})
    |> assign(:active_system_prompt, nil)
    |> assign(:waiting_for_response, false)
    |> assign(:is_streaming, false)
    |> assign(:agent_busy?, false)
    |> assign(:queued_messages, [])
    |> assign(:image_generation_enabled, true)
    |> assign(:video_generation_enabled, true)
    |> assign(:max_upload_bytes, nil)
  end

  defp favorited?(conv, user) do
    case Magus.Chat.get_conversation_favorite(conv.id, actor: user) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp active_share_links?(conv, user) do
    case Magus.Chat.get_active_share_links(conv.id, actor: user) do
      {:ok, links} -> links != []
      _ -> false
    end
  end

  # Read the persisted context-window snapshot for the donut. Returns the
  # `Magus.Chat.ContextWindow` struct or nil. Passes the current user as the
  # actor: the owner read policy authorizes the conversation owner.
  defp load_context_window(conversation_id, actor) do
    case Magus.Chat.get_context_window(conversation_id, actor: actor) do
      {:ok, cw} -> cw
      _ -> nil
    end
  end

  # True while a compaction is in flight for this conversation. nil-safe (no
  # window -> not compacting); :idle/:failed do not count. ChatInputComponent
  # carries its own copy of this helper for its send-lock; the message stream
  # needs it here to show the compaction indicator.
  defp compaction_in_progress?(nil), do: false

  defp compaction_in_progress?(context_window),
    do: Map.get(context_window, :compaction_status) in [:pending, :running]

  defp init_chat_input_assigns(socket, user, chat_mode, opts \\ []) do
    agent = Keyword.get(opts, :agent)

    all_models = Magus.Chat.list_active_models!()
    chat_models = Helpers.filter_chat_models(all_models)
    image_models = Enum.filter(all_models, &("image" in (&1.output_modalities || [])))
    video_models = Enum.filter(all_models, &("video" in (&1.output_modalities || [])))

    selected_model_id =
      (agent && agent.model_id) || Helpers.get_initial_model_id(user, chat_models)

    usage_limits = Helpers.compute_usage_state(user)

    socket
    |> assign(:chat_models, chat_models)
    |> assign(:image_models, image_models)
    |> assign(:video_models, video_models)
    |> assign(:selected_model_id, selected_model_id)
    |> assign(:selected_chat_model_id, selected_model_id)
    |> assign(:selected_image_model_id, agent && agent.image_model_id)
    |> assign(:selected_video_model_id, agent && agent.video_model_id)
    |> assign(:chat_mode, chat_mode)
    |> assign(:context_resources, [])
    |> assign(:image_generation_settings, %{})
    |> assign(:video_generation_settings, %{})
    |> assign(:active_system_prompt, nil)
    |> assign(:waiting_for_response, false)
    |> assign(:is_streaming, false)
    |> assign(:agent_busy?, false)
    |> assign(:queued_messages, [])
    |> assign(:image_generation_enabled, usage_limits.image_generation_enabled)
    |> assign(:video_generation_enabled, usage_limits.video_generation_enabled)
    |> assign(:max_upload_bytes, usage_limits.max_upload_bytes)
  end

  defp build_message_form(conversation, user) do
    Magus.Chat.form_to_create_message(
      actor: user,
      params: %{"conversation_id" => conversation.id}
    )
    |> to_form()
  end

  defp build_new_chat_message_form(user) do
    Magus.Chat.form_to_create_message(actor: user, params: %{})
    |> to_form()
  end

  defp open_thread_companion(thread_id, socket) do
    MagusWeb.Workbench.Signals.broadcast_open_companion(socket.assigns.tab_id, %{
      "type" => "thread",
      "id" => thread_id
    })

    {:noreply, socket}
  end

  defp extract_brain_page_id(%{result: %{"page_id" => id}}) when is_binary(id), do: id
  defp extract_brain_page_id(_), do: nil

  defp models_for_mode(:image_generation, _chat, image, _video), do: image
  defp models_for_mode(:video_generation, _chat, _image, video), do: video
  defp models_for_mode(_, chat, _image, _video), do: chat

  defp parse_role("companion"), do: :companion
  defp parse_role(_), do: :primary

  attr :role, :atom, required: true
  attr :conversation, :map, required: true
  attr :custom_agent, :map, default: nil
  attr :is_owner, :boolean, default: false
  attr :is_favorited, :boolean, default: false
  attr :has_active_share_links, :boolean, default: false
  attr :last_activity_at, :any, default: nil
  attr :editing_title?, :boolean, default: false
  attr :tab_id, :string, default: nil
  attr :user_id, :string, default: nil
  attr :workspace_id, :string, default: nil
  attr :current_user, :map, default: nil
  attr :viewers, :map, default: %{}

  defp chat_header_for_role(%{role: :companion} = assigns) do
    ~H"""
    <header class="px-3 py-2 border-b border-wb-border shrink-0 flex items-center gap-2">
      <button
        type="button"
        data-companion-back
        phx-click="close_companion"
        class="w-7 h-7 rounded-md hover:bg-wb-hover flex items-center justify-center text-wb-text-muted"
        aria-label="Close companion"
      >
        <.icon name="lucide-arrow-left" class="w-4 h-4" />
      </button>
      <h2 class="text-sm font-medium truncate">
        {@conversation.title || "Untitled conversation"}
      </h2>
    </header>
    """
  end

  defp chat_header_for_role(assigns) do
    ~H"""
    <header class="px-4 py-2 min-h-14 border-b border-wb-border shrink-0 flex items-center gap-3 md:pl-4 pl-14 md:pr-4 pr-14">
      <.link
        :if={@custom_agent}
        navigate={~p"/agents/#{@custom_agent.id}"}
        class="shrink-0"
      >
        <%= if @custom_agent.image_url do %>
          <img
            src={@custom_agent.image_url}
            class="w-8 h-8 rounded-full object-cover"
            alt={@custom_agent.name}
          />
        <% else %>
          <span class="w-8 h-8 rounded-full bg-wb-surface-2 flex items-center justify-center text-base">
            {@custom_agent.icon || "🤖"}
          </span>
        <% end %>
      </.link>
      <div class="flex flex-col min-w-0 flex-1">
        <div class="flex items-center gap-2 min-w-0">
          <%= if @editing_title? do %>
            <form phx-submit="save_title" class="flex-1 flex items-center gap-1">
              <input
                type="text"
                name="title"
                value={@conversation.title || ""}
                autofocus
                phx-keydown="cancel_edit_title"
                phx-key="Escape"
                class="flex-1 min-w-0 px-2 py-0.5 text-sm rounded bg-wb-surface-2 border border-wb-accent text-wb-text focus:outline-none"
              />
              <.inline_edit_actions cancel_event="cancel_edit_title" size={:sm} />
            </form>
          <% else %>
            <h2
              class={[
                "text-sm font-medium truncate",
                @is_owner && "cursor-pointer hover:text-wb-accent"
              ]}
              phx-click={@is_owner && "start_edit_title"}
            >
              {@conversation.title || "Untitled conversation"}
            </h2>
          <% end %>
          <span
            :if={@has_active_share_links}
            class="text-[10px] px-1.5 py-0.5 rounded bg-wb-surface-2 text-wb-text-muted border border-wb-border"
          >
            Shared
          </span>
          <span
            :if={@conversation.is_multiplayer}
            class="text-[10px] px-1.5 py-0.5 rounded bg-wb-surface-2 text-wb-text-muted border border-wb-border"
          >
            Multiplayer
          </span>
        </div>
        <div class="text-xs text-wb-text-muted truncate">
          <span :if={@custom_agent}>{@custom_agent.name}</span>
          <span :if={@custom_agent && @last_activity_at}>·</span>
          <span :if={@last_activity_at}>
            {MagusWeb.Workbench.Components.RelativeTime.relative(@last_activity_at)}
          </span>
        </div>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <.presence_indicator
          :if={@conversation}
          viewers={Map.get(@viewers || %{}, "presence:conversation:#{@conversation.id}", [])}
          current_user_id={@current_user.id}
          variant={:avatars}
          topic={"presence:conversation:#{@conversation.id}"}
        />
        <.workspace_share_button :if={@is_owner} resource={@conversation} />
        <button
          type="button"
          data-conversation-favorite
          phx-click="toggle_favorite_conversation"
          class="wb-pill-btn wb-pill-btn-square"
          aria-label={if @is_favorited, do: "Remove favorite", else: "Add favorite"}
        >
          <.icon
            name="lucide-star"
            class={["w-4 h-4", @is_favorited && "fill-warning text-warning"]}
          />
        </button>
        <button
          type="button"
          data-conversation-share
          phx-click="open_share_modal"
          class="wb-pill-btn wb-pill-btn-square"
          aria-label="Share"
        >
          <.icon name="lucide-share-2" class="w-4 h-4" />
        </button>
        <.live_component
          :if={@role == :primary}
          module={MagusWeb.Workbench.Tab.RightRail}
          id={"right-rail-#{@conversation.id}"}
          tab_id={@tab_id}
          user_id={@user_id}
          workspace_id={@workspace_id}
          conversation_id={@conversation.id}
        />
      </div>
    </header>
    """
  end
end
