defmodule MagusWeb.ChatLive.UI.ChatComponents do
  @moduledoc """
  Shared UI components for the chat interface.

  Contains reusable components like avatars, indicators, and separators
  that are used across multiple chat-related LiveViews and LiveComponents.
  """
  use MagusWeb, :html

  # ============================================================================
  # Avatar Components
  # ============================================================================

  @doc """
  Renders the AI agent's avatar image.
  """
  def agent_avatar(assigns) do
    ~H"""
    <div class="w-10 p-2 text-center justify-center flex items-center">
      <span class="text-primary text-3xl leading-none" alt={gettext("AI Assistant")}>◬</span>
    </div>
    """
  end

  @doc """
  Renders the AI agent's profile image (alias for agent_avatar).
  """
  def agent_profile_image(assigns), do: agent_avatar(assigns)

  @doc """
  Renders a user avatar for chat messages.
  Shows actual user avatar/initials when user is provided, otherwise shows a generic icon.
  Wrapped in w-10 container for DaisyUI chat component compatibility.
  """
  attr :user, :map, default: nil
  attr :is_own_message, :boolean, default: false

  def chat_user_avatar(assigns) do
    ~H"""
    <div class="w-10 h-10 flex-shrink-0">
      <%= if has_avatar_data?(@user) do %>
        <.user_avatar user={@user} size="md" />
      <% else %>
        <div class={[
          "w-10 h-10 rounded-full flex items-center justify-center",
          @is_own_message && "bg-base-300",
          !@is_own_message && "bg-primary/20"
        ]}>
          <.icon name="lucide-user" class="w-5 h-5 text-base-content/60" />
        </div>
      <% end %>
    </div>
    """
  end

  # Accepts either an Ash user struct or a plain map with `:email` (and
  # optionally `:avatar_path`). Rejects nils and Ash.NotLoaded so peer typing
  # payloads carrying just `%{email: _, avatar_path: _}` render correctly.
  defp has_avatar_data?(%Ash.NotLoaded{}), do: false
  defp has_avatar_data?(%{email: nil}), do: false
  defp has_avatar_data?(%{email: ""}), do: false
  defp has_avatar_data?(%{email: _}), do: true
  defp has_avatar_data?(_), do: false

  # ============================================================================
  # Indicator Components
  # ============================================================================

  @doc """
  Renders the thinking/loading indicator shown when AI is processing.
  Shows contextual status text alongside spinning logo.

  Status atoms: :thinking, :running_tools, :generating_response
  """
  attr :is_multiplayer, :boolean, default: false
  attr :status, :atom, default: :thinking

  def thinking_indicator(assigns) do
    status_text = thinking_status_text(assigns.status)
    assigns = assign(assigns, :status_text, status_text)

    ~H"""
    <div class="pt-2 ml-2" id="thinking-indicator">
      <div class="flex items-center gap-2 py-2 px-3 text-sm text-base-content/60">
        <.thinking_spinner />
        <span>{@status_text}...</span>
      </div>
    </div>
    """
  end

  # Inlined from the retired `MagusWeb.ChatLive` LiveView (Phase C5).
  # `lib/magus_web/workbench/chat/components/message/status_indicators.ex`
  # has its own gettext-aware copy used by message-level indicators; this
  # plain-string variant is used only by `thinking_indicator/1` above.
  defp thinking_status_text(:thinking), do: "Thinking"
  defp thinking_status_text(:reasoning), do: "Reasoning"
  defp thinking_status_text(:running_tools), do: "Running tools"
  defp thinking_status_text(:generating_response), do: "Generating response"
  defp thinking_status_text(:generating_image), do: "Generating image"
  defp thinking_status_text(:generating_video), do: "Generating video"
  defp thinking_status_text(_), do: "Thinking"

  @doc """
  Renders animated thinking spinner using the ◬ logo symbol.
  Used for AI thinking indicator.
  """
  def thinking_spinner(assigns) do
    ~H"""
    <span class="thinking-spinner">◬</span>
    """
  end

  @doc """
  Renders animated thinking dots.
  Used for multiplayer typing indicators.
  """
  def thinking_dots(assigns) do
    ~H"""
    <span class="thinking-dots">
      <span class="dot"></span>
      <span class="dot"></span>
      <span class="dot"></span>
    </span>
    """
  end

  @doc """
  Renders a typing indicator for a peer in collaborative conversations.
  """
  attr :user_id, :string, required: true
  attr :user_info, :map, default: %{}
  attr :is_multiplayer, :boolean, default: false

  def user_typing_indicator(assigns) do
    ~H"""
    <div class="chat chat-start" id={"typing-#{@user_id}"}>
      <div :if={@is_multiplayer} class="chat-image avatar">
        <.chat_user_avatar user={@user_info} />
      </div>
      <div class="message-bubble">
        <.thinking_dots />
      </div>
    </div>
    """
  end

  @doc """
  Render a single message bubble
  """
  attr :user_name, :string, required: true
  attr :timestamp, :any, default: nil
  attr :is_highlighted, :boolean, default: false
  attr :agent_label, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def message_bubble(assigns) do
    ~H"""
    <div class={[
      "message-bubble max-w-full",
      @is_highlighted == true && "highlighted"
    ]}>
      {render_slot(@inner_block)}
      <div
        :if={@user_name || @timestamp || @actions != []}
        class="flex items-center justify-between gap-2 text-xs text-base-content/50 mt-2 not-prose"
      >
        <div class="flex items-center">
          <span :if={@agent_label} class="text-primary font-medium">{@agent_label}</span>
          <span :if={@agent_label && @user_name} class="mx-1">·</span>
          <span :if={@user_name}>{@user_name}</span>
          <span :if={@user_name && @timestamp} class="mx-1">·</span>
          <.local_timestamp :if={@timestamp} timestamp={@timestamp} />
        </div>
        <div :if={@actions != []} class="flex items-center">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a timestamp that displays in the user's local timezone.
  Uses a JS hook to convert UTC to local time client-side.
  """
  attr :timestamp, :any, required: true
  attr :class, :string, default: nil

  def local_timestamp(assigns) do
    utc_iso = to_utc_iso(assigns.timestamp)
    assigns = assign(assigns, :utc_iso, utc_iso)

    ~H"""
    <span
      :if={@utc_iso}
      id={"ts-#{:erlang.phash2(@utc_iso)}"}
      class={@class}
      phx-hook=".LocalTimestamp"
      data-utc={@utc_iso}
    >
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTimestamp">
      export default {
        mounted() { this.formatTime() },
        updated() { this.formatTime() },
        formatTime() {
          const utc = this.el.dataset.utc
          if (!utc) return

          const date = new Date(utc)
          const now = new Date()
          const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
          const yesterday = new Date(today)
          yesterday.setDate(yesterday.getDate() - 1)
          const timestampDate = new Date(date.getFullYear(), date.getMonth(), date.getDate())

          const timeStr = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false })
          const daysDiff = Math.floor((today - timestampDate) / (1000 * 60 * 60 * 24))

          let formatted
          if (daysDiff === 0) {
            formatted = timeStr
          } else if (daysDiff === 1) {
            formatted = `Yesterday at ${timeStr}`
          } else if (daysDiff >= 2 && daysDiff <= 6) {
            const dayName = date.toLocaleDateString([], { weekday: 'long' })
            formatted = `${dayName} at ${timeStr}`
          } else if (date.getFullYear() === now.getFullYear()) {
            const monthDay = date.toLocaleDateString([], { month: 'short', day: 'numeric' })
            formatted = `${monthDay} at ${timeStr}`
          } else {
            const fullDate = date.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' })
            formatted = `${fullDate} at ${timeStr}`
          }

          this.el.textContent = formatted
        }
      }
    </script>
    """
  end

  defp to_utc_iso(nil), do: nil

  defp to_utc_iso(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end

  defp to_utc_iso(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  # ============================================================================
  # Queued Steering Messages
  # ============================================================================

  @doc """
  Renders the list of queued steering messages shown above the composer.

  Each queued message gets a dimmed row with a "Send now" and a "Remove"
  control. Payloads may arrive either as structs/atom-keyed maps (`%{id:, text:}`)
  or as string-keyed maps (`%{"id" =>, "text" =>}`) when delivered over PubSub.
  Renders nothing when the queue is empty.
  """
  attr :messages, :list, required: true

  def queued_messages_region(assigns) do
    ~H"""
    <div :if={@messages != []} class="px-3 py-2 space-y-1" data-queued-region>
      <div class="flex items-center gap-1.5 text-xs font-medium text-base-content/50">
        <.icon name="lucide-clock" class="w-3 h-3" />
        <span>{gettext("Queued")}</span>
      </div>
      <div
        :for={msg <- @messages}
        data-queued-message
        data-queued-id={queued_id(msg)}
        class="flex items-center gap-2 rounded-md bg-base-200/60 px-2 py-1 opacity-70"
      >
        <span class="flex-1 text-sm truncate text-base-content/70">{queued_text(msg)}</span>
        <button
          type="button"
          phx-click="send_now_queued"
          phx-value-id={queued_id(msg)}
          class="btn btn-xs btn-ghost"
          title={gettext("Send now")}
          aria-label={gettext("Send now")}
        >
          <.icon name="lucide-send" class="w-3.5 h-3.5" />
        </button>
        <button
          type="button"
          phx-click="remove_queued"
          phx-value-id={queued_id(msg)}
          class="btn btn-xs btn-ghost"
          title={gettext("Remove")}
          aria-label={gettext("Remove")}
        >
          <.icon name="lucide-x" class="w-3.5 h-3.5" />
        </button>
      </div>
    </div>
    """
  end

  defp queued_id(%{id: id}), do: id
  defp queued_id(%{"id" => id}), do: id
  defp queued_id(_), do: nil

  defp queued_text(%{text: text}), do: text
  defp queued_text(%{"text" => text}), do: text
  defp queued_text(_), do: ""
end
