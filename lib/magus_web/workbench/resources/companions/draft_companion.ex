defmodule MagusWeb.Workbench.Resources.Companions.DraftCompanion do
  @moduledoc """
  LiveView wrapper around the existing `DraftPaneComponent`. Mounted via
  `live_render` from `TabContainer` when a tab's companion is a draft.

  Receives in session:
    - `"draft_id"` — UUID of the draft
    - `"conversation_id"` — parent conversation UUID
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id (for broadcasting :close_companion back)

  Owns:
    - The draft data loading
    - Subscription to `"drafts:conversation:\#{conversation_id}"` for real-time
      updates (e.g., when an agent's WriteDraft tool updates the draft)
  """
  use MagusWeb, :live_view

  on_mount Magus.Presence

  import MagusWeb.Components.PresenceIndicator

  alias MagusWeb.ChatLive.Components.Draft.DraftPaneComponent
  alias MagusWeb.Workbench.Signals

  @impl true
  def mount(_params, session, socket) do
    draft_id = session["draft_id"]
    conversation_id = session["conversation_id"]
    user_id = session["user_id"]
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    case Magus.Drafts.get_draft(draft_id, actor: user) do
      {:ok, draft} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Magus.PubSub, "drafts:conversation:#{conversation_id}")
        end

        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:draft, draft)
         |> assign(:conversation_id, conversation_id)
         |> assign(:tab_id, tab_id)
         |> assign(:refining, false)
         |> Magus.Presence.track(:draft, draft.id)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:draft, nil)
         |> assign(:conversation_id, conversation_id)
         |> assign(:tab_id, tab_id)
         |> assign(:refining, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-draft-companion
      data-draft-id={if @draft, do: @draft.id, else: nil}
      class="h-full flex flex-col"
    >
      <div :if={@draft} class="flex items-center justify-end px-3 py-1 border-b border-base-200">
        <.presence_indicator
          viewers={Map.get(@viewers || %{}, "presence:draft:#{@draft.id}", [])}
          current_user_id={@current_user.id}
          variant={:avatars}
          topic={"presence:draft:#{@draft.id}"}
        />
      </div>
      <.live_component
        :if={@draft}
        module={DraftPaneComponent}
        id={"draft-companion-#{@draft.id}"}
        draft={@draft}
        conversation_id={@conversation_id}
        current_user={@current_user}
        refining={@refining}
      />
      <div :if={!@draft} class="flex-1 flex items-center justify-center text-wb-text-muted">
        <p>Draft not found.</p>
      </div>
    </div>
    """
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "draft.updated", payload: %{draft: draft}},
        socket
      )
      when not is_nil(socket.assigns.draft) and draft.id == socket.assigns.draft.id do
    {:noreply, assign(socket, :draft, draft)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "draft.created", payload: %{draft: draft}},
        socket
      )
      when is_nil(socket.assigns.draft) do
    {:noreply, assign(socket, :draft, draft)}
  end

  # `RefineDraftSelection` broadcasts `draft.refined` after the LLM rewrites
  # the selected text and the draft is updated. We swap in the new draft and
  # push `tiptap:set_content:draft` so the editor re-renders the document
  # with the rewritten section, then clear the `refining` spinner state.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "draft.refined", payload: %{draft: draft}},
        socket
      )
      when not is_nil(socket.assigns.draft) and draft.id == socket.assigns.draft.id do
    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:refining, false)
     |> push_event("tiptap:set_content:draft", %{content: draft.content})
     |> put_flash(
       :info,
       gettext("Selection refined (v%{version})", version: draft.version)
     )}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "draft.refine_failed"}, socket) do
    {:noreply,
     socket
     |> assign(:refining, false)
     |> put_flash(:error, gettext("Failed to refine selection"))}
  end

  # The DraftPaneComponent uses `notify_parent/1` (a `send(self(), ...)`) to
  # bubble action requests up. We are the parent LV here, so we own the
  # side-effects: kicking off review/export jobs against the parent
  # conversation's agent and surfacing flash errors when those fail.
  def handle_info(
        {DraftPaneComponent, {:review_draft, %{draft_id: draft_id, conversation_id: conv_id}}},
        socket
      ) do
    case Magus.Drafts.request_draft_review(draft_id, conv_id, actor: socket.assigns.current_user) do
      {:ok, _result} ->
        {:noreply, socket}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to start draft review"))}
    end
  end

  def handle_info(
        {DraftPaneComponent,
         {:export_draft, %{draft_id: draft_id, conversation_id: conv_id, export_format: format}}},
        socket
      ) do
    case Magus.Drafts.export_draft(draft_id, conv_id, format, actor: socket.assigns.current_user) do
      {:ok, _result} ->
        {:noreply, socket}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to start draft export"))}
    end
  end

  def handle_info(
        {DraftPaneComponent, {:restore_draft_version, %{version_id: version_id}}},
        socket
      ) do
    case socket.assigns.draft do
      nil ->
        {:noreply, socket}

      draft ->
        case Magus.Drafts.restore_draft_version(draft, version_id,
               actor: socket.assigns.current_user
             ) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:draft, updated)
             |> push_event("tiptap:set_content:draft", %{content: updated.content})
             |> put_flash(:info, gettext("Restored to v%{version}", version: updated.version))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to restore version"))}
        end
    end
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  @impl true
  def handle_event("close_draft_pane", _params, socket) do
    Signals.broadcast_close_companion(socket.assigns.tab_id)
    {:noreply, socket}
  end

  # The `TiptapEditor` JS hook pushes lifecycle events on every focus/blur
  # and (debounced) on content changes / autosaves. The autosave variant
  # (`tiptap:save`) is the only one we persist; the rest are LV-only and
  # we don't need to reflect them in assigns. Without these clauses the
  # LV crashes the moment the user tabs out of the editor.
  def handle_event("tiptap:save", %{"key" => "draft", "content" => content}, socket) do
    case socket.assigns.draft do
      nil ->
        {:noreply, socket}

      draft ->
        case Magus.Drafts.update_draft_content_json(draft, content,
               actor: socket.assigns.current_user
             ) do
          {:ok, updated} ->
            {:noreply, assign(socket, :draft, updated)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save draft changes"))}
        end
    end
  end

  def handle_event("tiptap:save", _params, socket), do: {:noreply, socket}
  def handle_event("tiptap:change", _params, socket), do: {:noreply, socket}
  def handle_event("tiptap:focus", _params, socket), do: {:noreply, socket}
  def handle_event("tiptap:blur", _params, socket), do: {:noreply, socket}

  # Bubble-menu "Refine" extra (configured in app.js) pushes
  # `draft:refine_selection` with the editor's selection payload (from/to/text/
  # node_context) and a free-text instruction. We resolve the surrounding
  # context here (draft + conversation), kick off RefineDraftSelection in a
  # supervised Task so the LV stays responsive, and let the action fan its
  # result back via the existing `drafts:conversation:<conv_id>` topic.
  def handle_event("draft:refine_selection", %{"text" => text} = params, socket)
      when is_binary(text) and byte_size(text) > 0 do
    case socket.assigns do
      %{draft: %{id: draft_id} = draft, conversation_id: conv_id, current_user: user}
      when not is_nil(draft) ->
        refine_params = %{
          draft_id: to_string(draft_id),
          selected_text: text,
          node_context: params["node_context"],
          hint_line: estimate_hint_line(draft.content, params["from"]),
          instruction:
            if(params["instruction"] in ["", nil],
              do: "Improve this text",
              else: params["instruction"]
            ),
          user_id: to_string(user.id),
          conversation_id: to_string(conv_id)
        }

        Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
          case Magus.Agents.Actions.RefineDraftSelection.run(refine_params, %{}) do
            {:ok, _result} ->
              :ok

            {:error, error} ->
              require Logger
              Logger.error("RefineDraftSelection failed: #{inspect(error)}")

              Magus.Endpoint.broadcast(
                "drafts:conversation:#{conv_id}",
                "draft.refine_failed",
                %{}
              )
          end
        end)

        {:noreply, assign(socket, :refining, true)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("draft:refine_selection", _params, socket), do: {:noreply, socket}

  # Bubble-menu "Ask" extra pushes `draft:ask_about_selection` with the
  # current selection. The chat input lives in a sibling LV
  # (ConversationView) on this tab, so we forward the selection to it via
  # the tab topic. ConversationView merges it into the next outgoing
  # message's metadata under "draft_selection", matching the legacy shape.
  def handle_event("draft:ask_about_selection", params, socket) do
    case socket.assigns.draft do
      nil ->
        {:noreply, socket}

      draft ->
        # Atom keys to match the chat input's `draft_selection_badge`
        # which accesses `selection.text` / `selection.hint_line`.
        payload = %{
          text: params["text"] || "",
          hint_line: estimate_hint_line(draft.content, params["from"]),
          draft_title: draft.title
        }

        Signals.broadcast_draft_selection(socket.assigns.tab_id, payload)
        {:noreply, socket}
    end
  end

  # Mirrors `MagusWeb.ChatLive.DraftHandlers.estimate_hint_line/2`. Kept in
  # the companion so we don't depend on the legacy module from a workbench
  # LV. Counts newlines in the plain-text projection of the doc up to the
  # selection start, giving the agent a 1-based line hint.
  defp estimate_hint_line(content, from)
       when is_map(content) and is_integer(from) and from >= 0 do
    plain = Magus.Drafts.ProseMirrorConverter.to_plain_text(content)
    clamped = min(from, String.length(plain))
    before = String.slice(plain, 0, clamped)
    1 + (before |> String.graphemes() |> Enum.count(&(&1 == "\n")))
  end

  defp estimate_hint_line(_content, _from), do: nil
end
