defmodule MagusWeb.ChatLive.Helpers do
  @moduledoc """
  Helper functions for the ChatLive module and its components.

  Contains utility functions for:
  - Conversation title formatting
  - Markdown rendering
  - Active stack compilation
  - Message ownership checks
  """

  use Gettext, backend: MagusWeb.Gettext

  require Ash.Query
  require Logger

  alias Magus.Usage.Calculator

  @doc """
  Returns `true` when the conversation should render collaborative UI
  (peer avatars, peer message bubbles, typing indicators).

  Requires `:is_collaborative` to be loaded on the conversation; raises
  loudly if it isn't, so a forgotten load surfaces immediately rather than
  silently turning collaborative UI off.
  """
  def collaborative?(%{is_collaborative: true}), do: true
  def collaborative?(%{is_collaborative: false}), do: false

  def collaborative?(other) do
    raise ArgumentError,
          "collaborative?/1 requires :is_collaborative loaded on the conversation, got: " <>
            inspect(other, limit: 5)
  end

  @doc """
  Builds a display-friendly conversation title string.
  Truncates long titles and handles nil values.
  """
  def build_conversation_title_string(title) do
    cond do
      title == nil -> "Untitled conversation"
      is_binary(title) && String.length(title) > 25 -> String.slice(title, 0, 25) <> "..."
      is_binary(title) && String.length(title) <= 25 -> title
    end
  end

  @doc """
  Converts markdown text to HTML using MDEx.
  Returns raw HTML for rendering in templates.
  """
  def to_markdown(text) do
    MDEx.to_html(text,
      extension: [
        strikethrough: true,
        tagfilter: true,
        table: true,
        autolink: true,
        tasklist: true,
        footnotes: true,
        shortcodes: true
      ],
      parse: [
        smart: true,
        relaxed_tasklist_matching: true,
        relaxed_autolinks: true
      ],
      render: [
        github_pre_lang: true,
        unsafe: true
      ],
      sanitize: MDEx.Document.default_sanitize_options()
    )
    |> case do
      {:ok, html} -> {:safe, html}
      {:error, _} -> text
    end
  end

  @doc """
  Compiles active stack blocks into a formatted prompt string.
  Each block is prefixed with its type label.
  """
  def compile_active_stack(blocks) do
    blocks
    |> Enum.map(fn block ->
      type_label =
        case block.type do
          :system -> "SYSTEM"
          :user -> "USER"
        end

      "[#{type_label}]\n#{block.content}"
    end)
    |> Enum.join("\n\n")
  end

  @doc """
  Checks if a message was created by the current user.
  Handles various states of the created_by relationship.
  """
  def is_own_message?(item, current_user) do
    created_by = Map.get(item, :created_by)

    cond do
      match?(%Ash.NotLoaded{}, created_by) ->
        Map.get(item, :created_by_id) == current_user.id

      is_map(created_by) && Map.has_key?(created_by, :id) ->
        created_by.id == current_user.id

      true ->
        Map.get(item, :created_by_id) == current_user.id
    end
  end

  @doc """
  Ensures the created_by relationship is loaded for proper message alignment.
  For the current user's messages, attaches the current_user directly.
  For other users' messages, loads from the database.
  """
  def ensure_created_by_loaded(message, current_user) do
    source = Map.get(message, :source)

    if source != :user do
      message
    else
      created_by = Map.get(message, :created_by)
      created_by_id = Map.get(message, :created_by_id)

      cond do
        is_map(created_by) && !match?(%Ash.NotLoaded{}, created_by) &&
            Map.has_key?(created_by, :id) ->
          message

        created_by_id == current_user.id ->
          Map.put(message, :created_by, current_user)

        is_struct(message) && created_by_id != nil ->
          case Ash.load(message, [:created_by], actor: current_user) do
            {:ok, loaded} -> loaded
            _ -> message
          end

        true ->
          message
      end
    end
  end

  @doc """
  Loads multiplayer data for a conversation.
  Returns a tuple of {members list, is_owner boolean}.
  """
  def load_multiplayer_data(conversation, current_user) do
    if conversation.is_multiplayer do
      members =
        Magus.Chat.get_accepted_members!(conversation.id, load: [:user], authorize?: false)

      is_owner =
        Enum.any?(members, fn m ->
          m.user_id == current_user.id && m.role == :owner
        end) || conversation.user_id == current_user.id

      {members, is_owner}
    else
      {[], conversation.user_id == current_user.id}
    end
  end

  @doc """
  Gets the selected model from the models list.
  """
  def get_selected_model(models, selected_id) do
    Enum.find(models, fn m -> m.id == selected_id end)
  end

  @doc """
  Updates or adds a folder to the folders list.
  """
  def update_or_add_folder(folders, updated_folder) do
    if Enum.any?(folders, &(&1.id == updated_folder.id)) do
      Enum.map(folders, fn f ->
        if f.id == updated_folder.id, do: updated_folder, else: f
      end)
    else
      [updated_folder | folders]
    end
  end

  @doc """
  Checks if a message has displayable content.
  Returns true if the message has non-empty text, attachments, or reasoning.

  Can accept either a message map or a message map with pre-loaded attachments.
  """
  def has_displayable_content?(message, loaded_attachments \\ nil) do
    text = Map.get(message, :text, "")
    reasoning = Map.get(message, :reasoning_summary, [])

    # Use provided attachments or fall back to message attachments
    attachments = loaded_attachments || Map.get(message, :attachments, [])

    has_text = is_binary(text) and String.trim(text) != ""
    has_attachments = is_list(attachments) and attachments != []
    has_reasoning = is_list(reasoning) and reasoning != []

    has_text or has_attachments or has_reasoning
  end

  @doc """
  Groups conversations by date categories based on their updated_at timestamp.
  Returns a list of {label, conversations} tuples in chronological order.
  Only includes groups that have conversations.
  """
  def group_conversations_by_date(conversations) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    # Define date boundaries
    yesterday = Date.add(today, -1)
    three_days_ago = Date.add(today, -3)
    seven_days_ago = Date.add(today, -7)
    thirty_days_ago = Date.add(today, -30)

    # Group conversations by last message date (fall back to updated_at)
    grouped =
      conversations
      |> Enum.group_by(fn conv ->
        conv_date = DateTime.to_date(conversation_sort_date(conv))

        cond do
          Date.compare(conv_date, today) == :eq -> :today
          Date.compare(conv_date, yesterday) == :eq -> :yesterday
          Date.compare(conv_date, three_days_ago) in [:eq, :gt] -> :last_3_days
          Date.compare(conv_date, seven_days_ago) in [:eq, :gt] -> :last_7_days
          Date.compare(conv_date, thirty_days_ago) in [:eq, :gt] -> :last_30_days
          true -> :older
        end
      end)

    # Define order and labels
    [
      {:today, gettext("Today")},
      {:yesterday, gettext("Yesterday")},
      {:last_3_days, gettext("Last 3 Days")},
      {:last_7_days, gettext("Last 7 Days")},
      {:last_30_days, gettext("Last 30 Days")},
      {:older, gettext("Older")}
    ]
    |> Enum.map(fn {key, label} ->
      convs = Map.get(grouped, key, [])
      {label, Enum.sort_by(convs, &conversation_sort_date/1, {:desc, DateTime})}
    end)
    |> Enum.reject(fn {_label, convs} -> convs == [] end)
  end

  defp conversation_sort_date(%{last_message_at: %DateTime{} = dt}), do: dt
  defp conversation_sort_date(%{updated_at: dt}), do: dt

  # ============================================================================
  # Model Selection Helpers
  # ============================================================================

  @doc """
  Gets the initial model ID for a user based on their preferences.
  Returns nil when no explicit selection exists (auto-routing mode).
  Only falls back to system default if the user's selected model is not in the available list.
  """
  def get_initial_model_id(current_user, models) do
    user_model_id = current_user.selected_model_id

    cond do
      is_nil(user_model_id) ->
        nil

      Enum.any?(models, &(&1.id == user_model_id)) ->
        user_model_id

      true ->
        # User has a selected model but it's not in the available list (deleted/disabled)
        nil
    end
  end

  @doc """
  Gets the initial image model ID for a user based on their preferences.
  Returns nil when no explicit selection exists (auto-routing mode).
  """
  def get_initial_image_model_id(current_user, image_models) do
    user_model_id = current_user.selected_image_model_id

    cond do
      is_nil(user_model_id) ->
        nil

      Enum.any?(image_models, &(&1.id == user_model_id)) ->
        user_model_id

      true ->
        nil
    end
  end

  @doc """
  Gets the initial video model ID for a user based on their preferences.
  Returns nil when no explicit selection exists (auto-routing mode).
  """
  def get_initial_video_model_id(current_user, video_models) do
    user_model_id = current_user.selected_video_model_id

    cond do
      is_nil(user_model_id) ->
        nil

      Enum.any?(video_models, &(&1.id == user_model_id)) ->
        user_model_id

      true ->
        nil
    end
  end

  @doc """
  Filters models to only include chat-capable models.
  Excludes image-only and video-only models.
  Keeps models that can output text, even if they also output images.
  """
  def filter_chat_models(models) do
    Enum.filter(models, fn model ->
      output_modalities = model.output_modalities || ["text"]
      "text" in output_modalities
    end)
  end

  @doc """
  Gets the appropriate model list and selected model ID for a given mode.
  Returns {models, selected_model_id, save_to_conversation}.
  """
  def get_models_for_mode(assigns, mode) do
    case mode do
      :image_generation ->
        {assigns.image_models, assigns.selected_image_model_id, false}

      :video_generation ->
        {assigns.video_models, assigns.selected_video_model_id, false}

      _ ->
        {assigns.chat_models, assigns.selected_model_id, false}
    end
  end

  @doc """
  Extracts the model ID from a belongs_to relationship.
  Handles NotLoaded, nil, and loaded model cases.
  """
  def get_model_id_from_relationship(%Ash.NotLoaded{}), do: nil
  def get_model_id_from_relationship(nil), do: nil
  def get_model_id_from_relationship(%Magus.Chat.Model{id: id}), do: id
  def get_model_id_from_relationship(%{id: id}), do: id
  def get_model_id_from_relationship(_), do: nil

  @doc """
  Gets the models list for the current chat mode.
  """
  def models_for_chat_mode(assigns) do
    case assigns.chat_mode do
      :image_generation -> assigns.image_models
      :video_generation -> assigns.video_models
      _ -> assigns.chat_models
    end
  end

  @doc """
  Returns merged slash commands (global + agent-specific) for the action menu.
  """
  def slash_commands_for_agent(nil), do: Magus.Agents.SlashCommands.list()

  def slash_commands_for_agent(agent) do
    Magus.Agents.SlashCommands.merge(Map.get(agent, :slash_commands, []))
  end

  @doc """
  Parses mode from form params (string) to atom.
  """
  def parse_mode(nil), do: :chat
  def parse_mode(mode) when is_atom(mode), do: mode
  def parse_mode("chat"), do: :chat
  def parse_mode("search"), do: :search
  def parse_mode("reasoning"), do: :reasoning
  def parse_mode("image_generation"), do: :image_generation
  def parse_mode("video_generation"), do: :video_generation
  def parse_mode(_), do: :chat

  # ============================================================================
  # Data Loading Helpers
  # ============================================================================

  @doc """
  Loads threads grouped by parent conversation ID for sidebar nesting.
  Fetches all threads for the given conversations in one pass.
  """
  def load_threads_for_sidebar(conversations, actor) do
    conversation_ids = Enum.map(conversations, & &1.id)

    if conversation_ids == [] do
      %{}
    else
      Magus.Chat.threads_for_conversations!(conversation_ids, actor: actor)
      |> Enum.group_by(& &1.parent_conversation_id)
    end
  end

  @doc """
  Loads the user's favorite conversations.
  """
  def load_favorite_conversations(current_user) do
    Magus.Chat.my_favorite_conversations!(actor: current_user)
  end

  @doc """
  Loads custom agents for @mention autocomplete.
  Returns a list of maps with :id, :name, :handle, :icon, :description.
  """
  def load_available_agents(current_user) do
    Magus.Agents.list_my_agents!(actor: current_user)
    |> Enum.reject(& &1.is_default)
    |> Enum.map(fn a ->
      %{id: a.id, name: a.name, handle: a.handle, icon: a.icon, description: a.description}
    end)
  end

  @doc """
  Checks if the favorites section should be collapsed based on user preferences.
  """
  def favorites_collapsed?(current_user) do
    get_in(current_user.ui_preferences || %{}, ["favorites_collapsed"]) || false
  end

  @doc """
  Loads folders for a user with conversations for expanded folders.
  Uses batch loading for efficiency.
  """
  def load_folders(current_user, expanded_folders) do
    require Ash.Query

    # Fetch all folders flat — no need to load :children since we build the tree in memory.
    all_folders = Magus.Chat.my_folders!(%{kinds: [:conversations, :mixed]}, actor: current_user)
    tree = build_folder_tree(all_folders)

    expanded_ids = collect_expanded_folder_ids(tree, expanded_folders)

    conversations_by_folder =
      if expanded_ids == [] do
        %{}
      else
        Magus.Chat.Conversation
        |> Ash.Query.filter(folder_id in ^expanded_ids and user_id == ^current_user.id)
        |> Ash.Query.load(:last_message_at)
        |> Ash.read!(actor: current_user)
        |> Enum.group_by(& &1.folder_id)
      end

    attach_conversations_to_folders(tree, conversations_by_folder, expanded_folders)
  end

  # Builds a nested folder tree from a flat list of folders.
  # Groups folders by parent_id, then recursively assigns children
  # starting from the root folders (parent_id == nil).
  defp build_folder_tree(all_folders) do
    by_parent = Enum.group_by(all_folders, & &1.parent_id)

    build_children(by_parent, nil)
  end

  defp build_children(by_parent, parent_id) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn folder ->
      children = build_children(by_parent, folder.id)
      %{folder | children: children}
    end)
  end

  @doc """
  Collects all expanded folder IDs from the folder tree.
  """
  def collect_expanded_folder_ids(folders, expanded_folders) do
    Enum.flat_map(folders, fn folder ->
      child_ids = collect_expanded_folder_ids(folder.children, expanded_folders)
      folder_id_str = to_string(folder.id)

      if Map.get(expanded_folders, folder_id_str, false) do
        [folder.id | child_ids]
      else
        child_ids
      end
    end)
  end

  @doc """
  Attaches conversations to folders based on expansion state.
  """
  def attach_conversations_to_folders(folders, conversations_by_folder, expanded_folders) do
    Enum.map(folders, fn folder ->
      folder_id_str = to_string(folder.id)

      folder =
        if Map.get(expanded_folders, folder_id_str, false) do
          conversations = Map.get(conversations_by_folder, folder.id, [])
          %{folder | conversations: conversations}
        else
          folder
        end

      children =
        attach_conversations_to_folders(
          folder.children,
          conversations_by_folder,
          expanded_folders
        )

      %{folder | children: children}
    end)
  end

  @doc """
  Loads expanded folder states for a user.
  """
  def load_expanded_folders(current_user) do
    current_user
    |> then(&Magus.Chat.my_folder_states!(actor: &1))
    |> Enum.filter(& &1.is_expanded)
    |> Map.new(&{to_string(&1.folder_id), true})
  end

  @doc """
  Loads messages for the legacy ChatLive. The workbench has its own private
  loader that gates on `:is_collaborative`; this function is a thin wrapper
  for the legacy view (which only knows about explicit multiplayer).
  """
  def load_messages(conversation, current_user) do
    if Map.get(conversation, :is_multiplayer, false) do
      Magus.Chat.message_history!(conversation.id,
        stream?: true,
        load: [:created_by, :responding_agent, :thread_count, :thread_message_count],
        actor: current_user
      )
    else
      Magus.Chat.message_history!(conversation.id,
        stream?: true,
        load: [:responding_agent, :thread_count, :thread_message_count],
        actor: current_user
      )
    end
  end

  @doc """
  Derives UI thinking state from agent state.

  Returns `{waiting_for_response, thinking_status}` where:
  - `waiting_for_response` controls the thinking indicator visibility
  - `thinking_status` determines which indicator variant to show

  State mapping:
  - `:idle` → `{false, nil}` - No activity
  - `:thinking` → `{true, :thinking}` - Agent preparing, waiting for LLM
  - `:streaming` → `{false, :generating_response}` - Text actively arriving (indicator hides)
  - `:reasoning` → `{true, :reasoning}` - Thinking/reasoning tokens arriving
  - `:tool_calling` → `{true, :running_tools}` - Executing tool calls
  - `:generating_image` → `{true, :generating_image}` - Image generation in progress
  - `:generating_video` → `{true, :generating_video}` - Video generation in progress
  """
  @spec derive_thinking_state(atom()) :: {boolean(), atom() | nil}
  def derive_thinking_state(:idle), do: {false, nil}
  def derive_thinking_state(:thinking), do: {true, :thinking}
  def derive_thinking_state(:streaming), do: {true, :generating_response}
  def derive_thinking_state(:reasoning), do: {true, :reasoning}
  def derive_thinking_state(:tool_calling), do: {true, :running_tools}
  def derive_thinking_state(:generating_image), do: {true, :generating_image}
  def derive_thinking_state(:generating_video), do: {true, :generating_video}
  # Backward compatibility — these legacy atoms were renamed in the signal refactor
  # (Feb 2026). Safe to remove once no in-flight signals use the old names.
  def derive_thinking_state(:tool_call), do: {true, :running_tools}
  def derive_thinking_state(:processing), do: {false, :generating_response}
  def derive_thinking_state(:waiting), do: {true, :thinking}
  def derive_thinking_state(_), do: {false, nil}

  # ============================================================================
  # Usage Limit Helpers
  # ============================================================================

  @doc """
  Computes the plan-level feature limits needed by the chat input.
  """
  def compute_usage_state(user) do
    limits = Calculator.get_effective_limits(user.id)

    if limits[:exempt] do
      %{
        image_generation_enabled: true,
        video_generation_enabled: true,
        max_upload_bytes: nil
      }
    else
      %{
        image_generation_enabled: limits[:image_generation_enabled] || false,
        video_generation_enabled: limits[:video_generation_enabled] || false,
        max_upload_bytes: limits[:max_upload_bytes]
      }
    end
  end

  # ============================================================================
  # Subscription & Broadcasting Helpers
  # ============================================================================

  @doc """
  Manages PubSub subscriptions when navigating between conversations.
  Unsubscribes from old conversation and subscribes to new one.

  Does not touch Magus.Presence tracking — callers that need presence tracking
  (e.g. the workbench ConversationView) must call Magus.Presence.track/untrack
  directly, since only LiveViews with the `on_mount Magus.Presence` hook can
  safely handle presence_diff broadcasts.
  """
  def manage_conversation_subscriptions(socket, conversation) do
    # Unsubscribe from old conversation
    if socket.assigns[:conversation] && socket.assigns[:conversation].id != conversation.id do
      old_id = socket.assigns.conversation.id
      detach_from_agent(old_id)
      Magus.Endpoint.unsubscribe("chat:messages:#{old_id}")
      Magus.Endpoint.unsubscribe("chat:conversations:#{old_id}")
      Magus.Endpoint.unsubscribe("chat:typing:#{old_id}")
      Magus.Endpoint.unsubscribe("agents:#{old_id}")
      Magus.Endpoint.unsubscribe("drafts:conversation:#{old_id}")
      Magus.Endpoint.unsubscribe("tasks:conversation:#{old_id}")

      if socket.assigns.conversation.is_multiplayer do
        Magus.Endpoint.unsubscribe("chat:members:#{old_id}")
        Magus.Endpoint.unsubscribe("chat:events:#{old_id}")
      end
    end

    # Subscribe to new conversation
    unless socket.assigns[:conversation] && socket.assigns[:conversation].id == conversation.id do
      Magus.Endpoint.subscribe("chat:messages:#{conversation.id}")
      Magus.Endpoint.subscribe("chat:conversations:#{conversation.id}")
      Magus.Endpoint.subscribe("chat:typing:#{conversation.id}")
      Magus.Endpoint.subscribe("agents:#{conversation.id}")
      Magus.Endpoint.subscribe("drafts:conversation:#{conversation.id}")
      Magus.Endpoint.subscribe("tasks:conversation:#{conversation.id}")

      if conversation.is_multiplayer do
        Magus.Endpoint.subscribe("chat:members:#{conversation.id}")
        Magus.Endpoint.subscribe("chat:events:#{conversation.id}")
      end

      attach_to_agent(conversation.id)
    end

    socket
  end

  @doc """
  Attaches the current process (LiveView) to the conversation agent,
  keeping it alive as long as the user has the chat open.
  """
  def attach_to_agent(conversation_id) do
    agent_id = "conv:#{conversation_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} -> Jido.AgentServer.attach(pid, self())
      :error -> :ok
    end
  rescue
    error ->
      Logger.debug("attach_to_agent failed for #{conversation_id}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Detaches the current process from the conversation agent,
  allowing the idle timer to start if no other viewers remain.
  """
  def detach_from_agent(conversation_id) do
    agent_id = "conv:#{conversation_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} -> Jido.AgentServer.detach(pid, self())
      :error -> :ok
    end
  rescue
    error ->
      Logger.debug("detach_from_agent failed for #{conversation_id}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Probes the agent for active streaming state after a LiveView remount.

  If the agent is currently generating a response, restores the thinking
  indicator and any accumulated streaming text so the user sees continuity
  instead of a dead chat after page reload.
  """
  def maybe_restore_streaming_state(socket, conversation_id) do
    agent_id = "conv:#{conversation_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} ->
        restore_from_agent(socket, pid)

      :error ->
        socket
    end
  rescue
    error ->
      Logger.debug(
        "maybe_restore_streaming_state failed for #{conversation_id}: #{Exception.message(error)}"
      )

      socket
  catch
    :exit, reason ->
      Logger.debug(
        "maybe_restore_streaming_state agent unresponsive for #{conversation_id}: #{inspect(reason)}"
      )

      socket
  end

  defp restore_from_agent(socket, pid) do
    alias Jido.AgentServer.Status

    case Jido.AgentServer.status(pid) do
      {:ok, %Status{} = agent_status} when agent_status.snapshot.status == :running ->
        details = agent_status.snapshot.details || %{}
        phase = details[:phase]
        streaming_text = details[:streaming_text]
        active_request_id = details[:active_request_id]
        {waiting, thinking_status} = derive_thinking_state(phase_to_state(phase))

        socket =
          socket
          |> Phoenix.Component.assign(:waiting_for_response, waiting)
          |> Phoenix.Component.assign(:thinking_status, thinking_status)

        # Restore in-progress tool calls from agent strategy snapshot
        socket = restore_in_progress_tool_calls(socket, details[:tool_calls])

        if is_binary(streaming_text) and streaming_text != "" and
             is_binary(active_request_id) do
          # Use turn-aware message ID to match what StreamingPlugin broadcasts.
          # On iteration > 0 (after tool calls), the ID differs from iteration 0.
          iteration = details[:iteration]

          message_id =
            if is_integer(iteration) and iteration > 0 do
              Magus.Agents.Plugins.Support.Helpers.response_id_for_turn(
                active_request_id,
                iteration
              )
            else
              Magus.Agents.Plugins.Support.Helpers.response_id_for_request(active_request_id)
            end

          streaming_message = %{
            id: message_id,
            text: streaming_text,
            role: :agent,
            source: :agent,
            message_type: :message,
            complete: false,
            inserted_at: DateTime.utc_now(),
            citations: [],
            reasoning_summary: [],
            attachments: [],
            disabled: false,
            model_name: nil
          }

          socket
          |> Phoenix.LiveView.stream_insert(:messages, streaming_message, at: 0)
          |> Phoenix.Component.assign(:is_streaming, true)
          |> Phoenix.Component.assign(:current_response_message_id, message_id)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp restore_in_progress_tool_calls(socket, tool_calls)
       when is_list(tool_calls) and tool_calls != [] do
    alias Magus.Agents.Plugins.Support.Helpers, as: PluginHelpers
    alias Magus.Agents.Tools.ToolBuilder

    now = DateTime.utc_now()
    tool_mapping = ToolBuilder.skill_tool_mapping()

    Enum.reduce(tool_calls, socket, fn tc, sock ->
      status = tc[:status]
      call_id = tc[:id]

      if status == :running and is_binary(call_id) do
        event_id = PluginHelpers.tool_event_id_for_call_id(call_id)
        tool_name = tc[:name] || "unknown"

        display_name =
          case tool_mapping[tool_name] do
            module when is_atom(module) and not is_nil(module) ->
              if function_exported?(module, :display_name, 0),
                do: module.display_name(),
                else: tool_name

            _ ->
              tool_name
          end

        tool_event = %{
          id: event_id,
          tool_name: tool_name,
          display_name: display_name,
          inputs: tc[:arguments] || %{},
          status: :in_progress,
          progress_items: [],
          steps: [],
          started_at: now,
          output_summary: nil,
          duration_ms: nil,
          error: nil
        }

        ephemeral_message = %{
          id: event_id,
          message_type: :event,
          source: :agent,
          complete: false,
          text: display_name,
          inserted_at: now,
          tool_call_data: tool_event
        }

        tracker = sock.assigns[:tool_event_tracker] || %{}

        sock
        |> Phoenix.Component.assign(:tool_event_tracker, Map.put(tracker, event_id, tool_event))
        |> Phoenix.LiveView.stream_insert(:messages, ephemeral_message, at: 0)
      else
        sock
      end
    end)
  end

  defp restore_in_progress_tool_calls(socket, _), do: socket

  # Maps strategy phase atoms to UI thinking states.
  # The catch-all returns :thinking for unexpected phases (e.g. :running, :completed)
  # which is safe since snapshot.status == :running guards the caller.
  defp phase_to_state(:awaiting_llm), do: :streaming
  defp phase_to_state(:awaiting_tool), do: :tool_calling
  defp phase_to_state(:idle), do: :idle
  defp phase_to_state(_), do: :thinking

  @doc """
  Broadcasts thinking state for multiplayer conversations.
  """
  def broadcast_thinking_state(socket, thinking) do
    Magus.Endpoint.broadcast(
      "chat:typing:#{socket.assigns.conversation.id}",
      "thinking",
      %{thinking: thinking}
    )
  end

  # ============================================================================
  # Prompt Generation Helpers
  # ============================================================================

  @doc """
  Generates a prompt from conversation messages using AI.
  """
  def generate_prompt_from_conversation(conversation_id, user_id \\ nil) do
    alias Magus.Agents.Actions.GeneratePromptFromConversation

    require Ash.Query

    messages =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^conversation_id)
      |> Ash.Query.filter(disabled != true)
      |> Ash.Query.filter(message_type == :message)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(50)
      |> Ash.read!(authorize?: false)
      |> Enum.map(fn msg -> %{source: msg.source, text: msg.text} end)

    GeneratePromptFromConversation.run(
      %{messages: messages, user_id: user_id, conversation_id: conversation_id},
      %{}
    )
  end

  @doc """
  Cancels the Oban job that's processing a response for the given message.
  """
  def cancel_oban_job_for_message(message_id) do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.queue == "chat_responses",
        where: j.state in ["available", "executing", "scheduled"],
        where: fragment("?->'primary_key'->>'id' = ?", j.args, ^message_id)
      )

    Oban.cancel_all_jobs(query)
  end

  @doc """
  Loads all drafts for a conversation, sorted by most recently updated.
  """
  def load_drafts_for_conversation(conversation_id, user) do
    case Magus.Drafts.list_drafts_for_conversation(conversation_id, actor: user) do
      {:ok, drafts} -> drafts
      _ -> []
    end
  end

  @doc """
  Loads workspaces the user is a member of.
  """
  def load_workspaces(current_user) do
    case Magus.Workspaces.my_workspaces(actor: current_user) do
      {:ok, workspaces} -> workspaces
      _ -> []
    end
  end

  @doc """
  Returns true — workspace creation is available to all users.
  """
  def can_create_workspace?(_current_user), do: true

  @doc """
  Restores the user's persisted workspace selection on mount.
  Returns {current_workspace, unfiled_conversations, team_conversations, chat_models, folders}.
  """
  def restore_workspace_selection(
        current_user,
        workspaces,
        chat_models,
        unfiled,
        folders,
        _expanded_folders
      ) do
    workspace_id = current_user.current_workspace_id

    workspace =
      if workspace_id do
        Enum.find(workspaces, &(&1.id == workspace_id))
      end

    if workspace do
      # Filter models by workspace allowed_model_ids if set
      filtered_models =
        if workspace.allowed_model_ids && workspace.allowed_model_ids != [] do
          allowed = MapSet.new(workspace.allowed_model_ids)
          Enum.filter(chat_models, &MapSet.member?(allowed, &1.id))
        else
          chat_models
        end

      # Load workspace conversations and split into team vs personal
      workspace_convs =
        Magus.Chat.workspace_conversations!(workspace.id, actor: current_user)

      {team, personal} =
        Enum.split_with(workspace_convs, fn conv ->
          conv.is_shared_to_workspace == true
        end)

      {workspace, personal, team, filtered_models, []}
    else
      {nil, unfiled, [], chat_models, folders}
    end
  end

  # ============================================================================
  # Context-Floor Boundary Helpers
  # ============================================================================

  @doc """
  Returns the id of the LAST out-of-window message (the newest message older
  than the floor), but ONLY when such a message is actually loaded
  (`oldest_at < floor`). The context-floor divider renders just BELOW this
  message, so it sits at the boundary between the dropped/summarized history and
  the live window.

  Anchoring to the last out-of-window message (rather than the first in-window
  one) means the divider:

    * appears the instant the floor advances past every message — e.g. right
      after a Clear, when nothing is in-window yet — instead of staying hidden
      until the next message arrives, and
    * stays pinned at the boundary as the conversation continues, instead of
      riding whatever the latest message happens to be.

  Returns `nil` when there is no floor, no loaded messages, or every loaded
  message is already in-window (so there is nothing to separate). The gate on
  `oldest_at < floor` keeps the query from running on the common case where the
  whole conversation is in-window.
  """
  def floor_boundary_id(_conversation_id, _oldest_at, nil, _actor), do: nil
  def floor_boundary_id(_conversation_id, nil, _floor, _actor), do: nil

  def floor_boundary_id(conversation_id, oldest_at, floor, actor) do
    if DateTime.compare(oldest_at, floor) == :lt do
      Magus.Chat.Message
      |> Ash.Query.for_read(:for_conversation, %{conversation_id: conversation_id}, actor: actor)
      |> Ash.Query.filter(inserted_at < ^floor and message_type == :message)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()
      |> case do
        [m | _] -> m.id
        [] -> nil
      end
    else
      nil
    end
  end

  @doc """
  Recomputes `:window_floor_boundary_id` from the current socket assigns and
  assigns it. Takes and returns a socket so callers can pipe through it after
  updating `:context_window` or `:oldest_message_at`.
  """
  def assign_floor_boundary(socket) do
    floor = socket.assigns[:context_window] && socket.assigns.context_window.window_start_at

    id =
      floor_boundary_id(
        socket.assigns.conversation_id,
        socket.assigns[:oldest_message_at],
        floor,
        socket.assigns.current_user
      )

    Phoenix.Component.assign(socket, :window_floor_boundary_id, id)
  end

  @doc """
  Recomputes the floor boundary and, when it MOVED, re-streams the affected
  boundary message(s) so the context-floor divider surfaces live.

  The divider is rendered as a child of the boundary stream item, gated on
  `:window_floor_boundary_id`. Reassigning that id alone does not re-render an
  already-streamed item, so a live floor advance (a completed compaction or a
  `Clear`) would otherwise not surface the divider until a full reload. We
  re-`stream_insert` the previous and new boundary messages (keyed by id, so
  the update is in place) to force the `:if` to re-evaluate: the new boundary
  gains its divider and any stale divider on the old boundary is dropped.

  No-ops on the common hot path (snapshot/usage updates that leave the floor
  unchanged): when the boundary id is identical, nothing is re-streamed.
  """
  def restream_floor_boundary(socket) do
    old_id = socket.assigns[:window_floor_boundary_id]
    socket = assign_floor_boundary(socket)
    new_id = socket.assigns.window_floor_boundary_id

    if old_id == new_id do
      socket
    else
      [old_id, new_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(socket, &reinsert_stream_message(&2, &1))
    end
  end

  # Re-stream a single message by id using the same load shape the stream was
  # seeded with, so the re-inserted item renders identically. `update_only:
  # true` keeps this a pure in-place refresh: if the boundary message is not in
  # the loaded window (it normally is — it is the first in-window message) it is
  # NOT inserted, which would otherwise misplace it at the top of the stream.
  # Missing/forbidden reads are a no-op (the divider simply stays as-is).
  defp reinsert_stream_message(socket, message_id) do
    case Magus.Chat.get_message(message_id,
           actor: socket.assigns.current_user,
           load: message_stream_load(socket.assigns.conversation)
         ) do
      {:ok, message} ->
        Phoenix.LiveView.stream_insert(socket, :messages, message, update_only: true)

      _ ->
        socket
    end
  end

  @doc """
  Ash `load:` list for messages rendered in the chat stream. Shared by the
  initial/paged load and the floor-boundary re-stream so a re-inserted message
  carries exactly the same calculations as the ones already in the stream.
  """
  def message_stream_load(conversation) do
    if collaborative?(conversation),
      do: [:created_by, :responding_agent, :thread_count, :thread_message_count],
      else: [:responding_agent, :thread_count, :thread_message_count]
  end
end
