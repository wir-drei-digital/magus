defmodule MagusWeb.Workbench.Signals do
  @moduledoc """
  PubSub naming + broadcast helpers for workbench tab-scoped signals.

  ## Companion spec shapes

  Each companion type broadcasts a spec with the following keys:

      %{"type" => "draft",        "id" => <draft_uuid>}
      %{"type" => "thread",       "id" => <thread_conversation_uuid>}
      %{"type" => "service",      "id" => <conversation_uuid>}
      %{"type" => "pdf",          "id" => <file_uuid>,
                                  "name" => <filename>,
                                  "url" => <preview_url>}
      %{"type" => "brain_page",   "id" => <page_uuid>}            # Phase 4
      %{"type" => "conversation", "id" => <conversation_uuid>}    # Tab chrome polish

  Services key their id on the conversation id since they are a
  single "pane" per conversation rather than a distinct resource. Pdf carries
  pre-resolved name + url because the PDF viewer renders from a URL, not from
  a DB lookup.
  """

  @type tab_id :: String.t()
  @type draft_spec :: %{required(String.t()) => String.t()}
  @type thread_spec :: %{required(String.t()) => String.t()}
  @type service_spec :: %{required(String.t()) => String.t()}
  @type pdf_spec :: %{required(String.t()) => String.t()}
  @type conversation_spec :: %{required(String.t()) => String.t()}
  @type companion_spec ::
          draft_spec()
          | thread_spec()
          | service_spec()
          | pdf_spec()
          | conversation_spec()

  @spec tab_topic(tab_id()) :: String.t()
  def tab_topic(tab_id) when is_binary(tab_id), do: "workbench:tab:#{tab_id}"

  @doc """
  Topic for shell-level notifications scoped to a single user. Used by
  TabContainer to notify WorkbenchLive about companion persistence without
  leaking into other users' sessions.
  """
  @spec workbench_user_topic(String.t()) :: String.t()
  def workbench_user_topic(user_id) when is_binary(user_id),
    do: "workbench:user:#{user_id}"

  @spec broadcast_open_companion(tab_id(), companion_spec()) :: :ok | {:error, term()}
  def broadcast_open_companion(tab_id, spec)
      when is_binary(tab_id) and is_map(spec) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_companion, {:open, spec}}
    )
  end

  @spec broadcast_close_companion(tab_id()) :: :ok | {:error, term()}
  def broadcast_close_companion(tab_id) when is_binary(tab_id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_companion, :close}
    )
  end

  @doc """
  Broadcasts an active-system-prompt change to listeners of the tab's topic.
  `prompt` may be `nil` to indicate deactivation. Used by `TabContainer` to
  notify `ConversationView` (which lives in a separate LV process via
  `live_render`) so the chat input updates its active-prompt indicator.
  """
  @spec broadcast_active_prompt(tab_id(), map() | nil) :: :ok | {:error, term()}
  def broadcast_active_prompt(tab_id, prompt) when is_binary(tab_id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_chrome, {:active_prompt, prompt}}
    )
  end

  @doc """
  Broadcasts a request to insert text into the chat input. Listeners
  forward this via `push_event(socket, "insert_text", %{text: text})` to
  the JS `ChatTextarea` hook in their own process.
  """
  @spec broadcast_insert_text(tab_id(), String.t()) :: :ok | {:error, term()}
  def broadcast_insert_text(tab_id, text) when is_binary(tab_id) and is_binary(text) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_chrome, {:insert_text, text}}
    )
  end

  @doc """
  Broadcasts a PDF text-selection payload (text + screenshot + page) to
  listeners of the tab's topic. Used by `FileView` (file-as-parent) to
  forward `pdf:ask_about_selection` events to the chat companion's LV.
  """
  @spec broadcast_pdf_selection(tab_id(), map()) :: :ok | {:error, term()}
  def broadcast_pdf_selection(tab_id, payload) when is_binary(tab_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_chrome, {:pdf_selection, payload}}
    )
  end

  @doc """
  Broadcasts a draft text-selection payload (text + hint_line + draft_title)
  to listeners of the tab's topic. Used by `DraftCompanion` to forward the
  bubble-menu `draft:ask_about_selection` event to the parent
  `ConversationView`, which stashes it as `:draft_selection` and merges it
  into the next outgoing message's metadata.
  """
  @spec broadcast_draft_selection(tab_id(), map()) :: :ok | {:error, term()}
  def broadcast_draft_selection(tab_id, payload)
      when is_binary(tab_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_chrome, {:draft_selection, payload}}
    )
  end

  @doc """
  Broadcasts a brain text-selection payload (text + page_title) to listeners
  of the tab's topic. Used by `BrainPageView` to forward the bubble-menu
  `brain:ask_about_selection` event to the chat that hosts the input on
  this tab — either a sibling primary `ConversationView` (when the brain
  is a companion) or a freshly-opened companion chat (when the brain is
  primary). The chat stashes it as `:brain_selection` so the next message
  goes out with the highlighted text in context.
  """
  @spec broadcast_brain_selection(tab_id(), map()) :: :ok | {:error, term()}
  def broadcast_brain_selection(tab_id, payload)
      when is_binary(tab_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      tab_topic(tab_id),
      {:workbench_chrome, {:brain_selection, payload}}
    )
  end

  @doc """
  Broadcasts that conversation favorites for a user have changed. The
  conversation view (a sticky `live_render` LV with no direct handle on
  the chat-mode-nav LiveComponent) uses this to ask `WorkbenchLive` to
  reload its nav tree so favorites added/removed from the chat header
  show up in the sidebar.
  """
  @spec broadcast_favorites_changed(String.t()) :: :ok | {:error, term()}
  def broadcast_favorites_changed(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      workbench_user_topic(user_id),
      {:workbench_user, :conversation_favorites_changed}
    )
  end

  @doc """
  Broadcasts that billable usage was recorded for a user so the workbench
  shell can refresh its pay-as-you-go usage indicator. Sent by
  `Magus.Agents.Persistence.UsageRecorder` after billable usage is recorded
  (live chat/image/video responses) or reconciled out of band, since usage is
  generated inside child conversation LVs that the shell can't observe
  directly. `WorkbenchLive` recomputes `MagusWeb.Workbench.Live.Usage` on receipt.
  """
  @spec broadcast_usage_changed(String.t()) :: :ok | {:error, term()}
  def broadcast_usage_changed(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      workbench_user_topic(user_id),
      {:workbench_user, :usage_changed}
    )
  end
end
