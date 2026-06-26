defmodule MagusWeb.ConversationChannel do
  @moduledoc """
  Per-conversation channel (`conversation:<conversation_id>`) for the
  SvelteKit workbench.

  A thin bridge (migration spec invariant 1 — broadcast shapes are frozen):
  join authorizes through the same Ash policies as every other caller
  (`Magus.Chat.get_conversation/2` with the socket's user as actor), then
  subscribes to the conversation's existing PubSub topics and forwards
  broadcasts as channel pushes:

    * `agents:<id>` — agent signal stream; pushed under the signal's own
      `type` (`text.chunk`, `thinking.chunk`, `text.complete`, `tool.start`,
      `tool.progress`, `tool.complete`, `turn.*`, `run.*`, `state.change`,
      `response.complete`, `error`, ...), payload forwarded unchanged.
    * `chat:messages:<id>` — message persistence events; pushed as
      `message.<ash action>` (`message.create`, `message.send_user_message`,
      `message.upsert_response`, `message.create_event`, ...).
    * `chat:queued:<id>`: queued-message lifecycle events; pushed as
      `queued.<event>` (`queued.enqueue_message`, `queued.flush_queued`,
      `queued.remove_queued`).
    * `chat:typing:<id>` — pushed as `typing.<event>` (`typing.user_typing`,
      `typing.thinking`).
    * `chat:access:<id>` — `access_revoked` is pushed as `access.revoked`,
      then the channel shuts down (the client re-joins to re-authorize).
    * `drafts:conversation:<id>` — draft lifecycle events
      (`draft.created` / `draft.updated` / `draft.refined` / ...). The
      PubSub payload carries the full `Magus.Drafts.Draft` struct (not
      JSON-encodable), so this is the one bridge that reshapes: the push
      payload is a JSON-safe summary map. The PubSub shape LiveView
      consumes is untouched.
  """
  use MagusWeb, :channel

  require Logger

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    case Magus.Chat.get_conversation(conversation_id,
           actor: socket.assigns.current_user,
           load: [:is_collaborative]
         ) do
      {:ok, conversation} ->
        for topic <- subscribed_topics(conversation.id) do
          Magus.Endpoint.subscribe(topic)
        end

        {:ok,
         socket
         |> assign(:conversation_id, conversation.id)
         |> assign(:collaborative?, conversation.is_collaborative)}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  # Outbound typing from the SPA composer. Broadcast shape is frozen — it
  # mirrors the classic chat input's `user_typing` broadcast exactly, so
  # LiveView participants in the same conversation see SPA users typing.
  # Only collaborative conversations broadcast (same guard as classic).
  @impl true
  def handle_in("typing", %{"is_typing" => is_typing}, socket) when is_boolean(is_typing) do
    if socket.assigns[:collaborative?] do
      user = socket.assigns.current_user

      Magus.Endpoint.broadcast(
        "chat:typing:#{socket.assigns.conversation_id}",
        "user_typing",
        %{
          user_id: user.id,
          user_name: user.display_name || to_string(user.email),
          avatar_path: Map.get(user, :avatar_path),
          email: to_string(user.email),
          is_typing: is_typing
        }
      )
    end

    {:noreply, socket}
  end

  # User pressed Stop. Mirror the classic `stop_response` handler: cancel any
  # queued resume-generation jobs, cast `message.cancel` to the conversation
  # agent (the ReAct runner's `check_cancel!` ends the turn), and post a
  # "Response cancelled" event. Join already authorized the actor for this
  # conversation, so any member who can view it may stop the response.
  def handle_in("cancel_response", _payload, socket) do
    conversation_id = socket.assigns.conversation_id

    cancel_resume_jobs(conversation_id)
    signal_agent_cancel(conversation_id)

    Magus.Chat.create_event_message!("Response cancelled", conversation_id, authorize?: false)

    {:reply, :ok, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # Cast `message.cancel` to the conversation agent if one is live. Tolerates the
  # InstanceManager registry being absent (e.g. the agent subsystem isn't up, or
  # in tests): lookup/2 raises rather than returning :error there, and a cancel
  # with no running agent is simply a no-op.
  defp signal_agent_cancel(conversation_id) do
    case Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{conversation_id}") do
      {:ok, pid} ->
        signal = Jido.Signal.new!("message.cancel", %{conversation_id: conversation_id})
        Jido.AgentServer.cast(pid, signal)

      :error ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # Resume-generation jobs (queue `chat_responses`) are keyed by conversation_id
  # in their args; cancel the in-flight/queued ones so a cancelled turn isn't
  # resumed after hibernation.
  defp cancel_resume_jobs(conversation_id) do
    import Ecto.Query

    from(j in Oban.Job,
      where: j.queue == "chat_responses",
      where: j.state in ["available", "executing", "scheduled"],
      where: fragment("?->>'conversation_id' = ?", j.args, ^conversation_id)
    )
    |> Oban.cancel_all_jobs()
  end

  defp subscribed_topics(conversation_id) do
    [
      "agents:#{conversation_id}",
      "chat:messages:#{conversation_id}",
      "chat:message_deletes:#{conversation_id}",
      "chat:queued:#{conversation_id}",
      "chat:typing:#{conversation_id}",
      "chat:access:#{conversation_id}",
      "drafts:conversation:#{conversation_id}"
    ]
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{topic: "agents:" <> _, payload: payload}, socket) do
    case payload do
      %{type: type} when is_binary(type) ->
        push(socket, type, payload)

      _ ->
        # Every signal in Magus.Agents.Signals carries a binary :type today;
        # a payload without one means a new/changed producer the bridge can't
        # forward. Log it — silently dropping makes streaming "just stop".
        Logger.warning(
          "ConversationChannel dropped agents: broadcast without binary :type: #{inspect(payload, limit: 5)}"
        )
    end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:messages:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "message." <> event, payload)
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:message_deletes:" <> _, payload: payload},
        socket
      ) do
    push(socket, "message.destroy", payload)
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:queued:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "queued." <> event, payload)
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:typing:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "typing." <> event, payload)
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:access:" <> _,
          event: "access_revoked",
          payload: payload
        },
        socket
      ) do
    push(socket, "access.revoked", payload)
    {:stop, :normal, socket}
  end

  # Draft lifecycle. Events arrive pre-prefixed ("draft.created", ...) and
  # carry the full Draft struct, which isn't JSON-encodable — push a summary
  # instead. Deliberately content-free (no title/body): draft read policies
  # are narrower than conversation read (e.g. per-user conversation grants
  # don't see drafts), so the bridge only signals THAT something changed and
  # the SPA refetches via the policy-gated get_draft.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "drafts:conversation:" <> _, event: event} = broadcast,
        socket
      ) do
    case broadcast.payload do
      %{draft: draft} ->
        push(socket, event, %{
          "draft" => %{
            "id" => draft.id,
            "version" => draft.version,
            "conversation_id" => draft.conversation_id,
            "updated_at" => draft.updated_at
          }
        })

      _ ->
        push(socket, event, %{})
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
