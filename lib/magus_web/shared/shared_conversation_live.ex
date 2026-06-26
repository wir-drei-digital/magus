defmodule MagusWeb.SharedConversationLive do
  @moduledoc """
  Read-only view for shared conversations.

  This page displays a conversation to users with a valid share link token.
  The view is read-only - no message input or participation UI is shown.

  Access types:
  - Public links: Anyone with the link can view (no login required)
  - Authenticated links: Only logged-in users can view
  """
  use MagusWeb, :live_view

  import MagusWeb.ChatLive.UI.ChatComponents, only: [message_bubble: 1]
  import MagusWeb.ChatLive.Components.Message.ThinkingIndicators, only: [reasoning_display: 1]

  import MagusWeb.ChatLive.Components.Message.Events,
    only: [event_message: 1, job_trigger_message: 1]

  import MagusWeb.ChatLive.Components.Message.Actions, only: [citations_display: 1]

  import MagusWeb.ChatLive.Components.Message.Helpers,
    only: [to_markdown: 3, get_referenced_citations: 2]

  import MagusWeb.ChatLive.Helpers, only: [has_displayable_content?: 2]

  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      page_title={@page_title}
      show_sidebar={false}
      hide_mobile_menu={false}
      bg_class="bg-spectral"
    >
      <%= if @error do %>
        <.error_view error={@error} return_path={@return_path} />
      <% else %>
        <.shared_conversation_view
          conversation={@conversation}
          share_link={@share_link}
          streams={@streams}
        />
      <% end %>
    </Layouts.app>
    """
  end

  attr :error, :atom, required: true
  attr :return_path, :string, required: true

  defp error_view(assigns) do
    ~H"""
    <div class="min-h-[calc(100vh-3.5rem)] flex items-center justify-center">
      <div class="card w-96 bg-base-200 shadow-xl">
        <div class="card-body text-center">
          <%= case @error do %>
            <% :not_found -> %>
              <.icon name="lucide-link-2-off" class="w-16 h-16 mx-auto text-base-content/30 mb-4" />
              <h2 class="card-title justify-center">{gettext("Link Not Found")}</h2>
              <p class="text-base-content/70">
                {gettext("This share link is invalid or has been revoked.")}
              </p>
            <% :requires_login -> %>
              <.icon name="lucide-lock" class="w-16 h-16 mx-auto text-base-content/30 mb-4" />
              <h2 class="card-title justify-center">{gettext("Login Required")}</h2>
              <p class="text-base-content/70">
                {gettext("This conversation requires you to be logged in to view.")}
              </p>
              <div class="card-actions justify-center mt-4">
                <.link navigate={~p"/sign-in?return_to=#{@return_path}"} class="btn btn-primary">
                  {gettext("Sign In")}
                </.link>
              </div>
          <% end %>
          <div class="card-actions justify-center mt-4">
            <.link navigate={~p"/"} class="btn btn-ghost">
              {gettext("Go Home")}
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :conversation, :map, required: true
  attr :share_link, :map, required: true
  attr :streams, :map, required: true

  defp shared_conversation_view(assigns) do
    ~H"""
    <div class="flex flex-col min-h-[calc(100vh-3.5rem)]">
      <%!-- Conversation Info Bar --%>
      <div class="border-b border-base-300 bg-base-100/80">
        <div class="max-w-4xl mx-auto px-4 py-3">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="font-semibold text-lg">
                {@conversation.title || gettext("Untitled Conversation")}
              </h1>
              <p class="text-xs text-base-content/60">
                {gettext("Shared conversation")}
                <span :if={@share_link.access_type == :authenticated} class="ml-1">
                  <.icon name="lucide-lock" class="w-3 h-3 inline" />
                </span>
              </p>
            </div>
            <div class="badge badge-ghost gap-1">
              <.icon name="lucide-eye" class="w-3 h-3" />
              {gettext("Read-only")}
            </div>
          </div>
        </div>
      </div>

      <%!-- Messages --%>
      <main class="flex-1 max-w-4xl mx-auto w-full px-4 py-6">
        <div class="flex flex-col gap-0" id="shared-messages" phx-update="stream">
          <div :for={{dom_id, item} <- @streams.messages} id={dom_id} class={stream_item_class(item)}>
            <.shared_item item={item} />
          </div>
        </div>

        <%!-- Empty state --%>
        <div :if={@conversation.message_count == 0} class="text-center py-12 text-base-content/50">
          <.icon name="lucide-message-circle" class="w-12 h-12 mx-auto mb-4" />
          <p>{gettext("No messages in this conversation yet.")}</p>
        </div>
      </main>

      <%!-- Footer --%>
      <footer class="">
        <div class="max-w-4xl mx-auto px-4 pt-5 pb-8">
          <div class="flex justify-center">
            <.link navigate={~p"/register"} class="btn btn-primary px-16">
              {gettext("Try MAGUS Free")}
            </.link>
          </div>
        </div>
      </footer>
    </div>
    """
  end

  attr :item, :map, required: true

  defp shared_item(assigns) do
    has_content = has_displayable_content?(assigns.item, [])
    message_type = Map.get(assigns.item, :message_type)
    alignment = if assigns.item.source == :agent, do: "start", else: "end"
    user_name = if assigns.item.source == :agent, do: Map.get(assigns.item, :model_name)

    # Only show event messages that have tool data or text content
    tool_data = Map.get(assigns.item, :tool_call_data)
    has_tool_data = is_map(tool_data) and map_size(tool_data) > 0

    # Check for reasoning-only messages (reasoning but no text)
    text = Map.get(assigns.item, :text, "")
    has_text = is_binary(text) and String.trim(text) != ""
    reasoning = Map.get(assigns.item, :reasoning_summary, [])
    has_reasoning = is_list(reasoning) and reasoning != []
    reasoning_only = has_reasoning and not has_text

    assigns =
      assigns
      |> assign(:has_content, has_content)
      |> assign(:has_tool_data, has_tool_data)
      |> assign(:message_type, message_type)
      |> assign(:alignment, alignment)
      |> assign(:user_name, user_name)
      |> assign(:reasoning_only, reasoning_only)

    ~H"""
    <%= cond do %>
      <% @message_type == :event and (@has_content or @has_tool_data) -> %>
        <.event_message item={@item} is_multiplayer={false} />
      <% @message_type == :job_trigger -> %>
        <.job_trigger_message item={@item} is_multiplayer={false} />
      <% !@has_content -> %>
      <% @reasoning_only -> %>
        <div class="max-w-full pr-12">
          <.reasoning_display reasoning_summary={Map.get(@item, :reasoning_summary, [])} />
        </div>
      <% true -> %>
        <div class={[
          "group overflow-x-auto w-full pb-4",
          @alignment,
          @alignment == "start" && "pr-12",
          @alignment == "end" && "pl-12"
        ]}>
          <div class="flex flex-col overflow-x-auto w-full">
            <.message_bubble
              user_name={@user_name}
              timestamp={Map.get(@item, :inserted_at)}
              is_highlighted={false}
            >
              <% citations = Map.get(@item, :citations, []) %>
              <% referenced_citations = get_referenced_citations(@item.text, citations) %>
              <div
                id={"message-text-#{@item.id}"}
                phx-hook="RichContent"
                class="overflow-x-auto prose prose-sm prose-a:text-blue-600 prose-a:hover:text-blue-500 dark:prose-invert"
              >
                {to_markdown(@item.text, citations, id: @item.id)}
              </div>

              <.citations_display citations={referenced_citations} />
            </.message_bubble>
          </div>
        </div>
    <% end %>
    """
  end

  # ============================================================================
  # Mount
  # ============================================================================

  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:token, token)
      |> assign(:return_path, "/shared/#{token}")

    case Magus.Chat.get_share_link_by_token(token, authorize?: false) do
      {:ok, share_link} ->
        case check_access(share_link, socket.assigns.current_user) do
          :ok ->
            conversation = load_conversation(share_link.conversation_id)
            messages = load_messages(conversation)

            {:ok,
             socket
             |> assign(:error, nil)
             |> assign(:share_link, share_link)
             |> assign(:conversation, conversation)
             |> assign(:page_title, conversation.title || "Shared Conversation")
             |> stream(:messages, messages)}

          :requires_login ->
            {:ok,
             socket
             |> assign(:error, :requires_login)
             |> assign(:page_title, gettext("Login Required"))
             |> assign(:conversation, nil)
             |> assign(:share_link, share_link)
             |> stream(:messages, [])}
        end

      {:error, _} ->
        # Token not found or invalid
        {:ok,
         socket
         |> assign(:error, :not_found)
         |> assign(:page_title, gettext("Link Not Found"))
         |> assign(:conversation, nil)
         |> assign(:share_link, nil)
         |> stream(:messages, [])}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp check_access(%{access_type: :public}, _user), do: :ok
  defp check_access(%{access_type: :authenticated}, nil), do: :requires_login
  defp check_access(%{access_type: :authenticated}, _user), do: :ok

  defp load_conversation(conversation_id) do
    Magus.Chat.get_conversation!(conversation_id,
      authorize?: false,
      load: [:user, :message_count]
    )
  end

  defp load_messages(conversation) do
    Magus.Chat.message_history!(conversation.id,
      authorize?: false,
      query: [sort: [inserted_at: :asc]]
    )
  end

  # Determine CSS class for stream item based on message type
  # Used for consistent spacing via CSS selectors
  defp stream_item_class(item) do
    message_type = Map.get(item, :message_type)

    cond do
      # Event messages (tool calls, etc.)
      message_type == :event ->
        "msg-type-event"

      # Job trigger messages
      message_type == :job_trigger ->
        "msg-type-event"

      # Regular messages - check if reasoning only
      true ->
        text = Map.get(item, :text, "")
        has_text = is_binary(text) and String.trim(text) != ""
        reasoning = Map.get(item, :reasoning_summary, [])
        has_reasoning = is_list(reasoning) and reasoning != []

        if has_reasoning and not has_text do
          "msg-type-event"
        else
          "msg-type-bubble"
        end
    end
  end
end
