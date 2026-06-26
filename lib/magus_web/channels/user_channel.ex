defmodule MagusWeb.UserChannel do
  @moduledoc """
  Per-user channel (`user:<user_id>`) for the SvelteKit workbench.

  A thin bridge: joins are authorized against the socket's authenticated
  user, then the channel subscribes to existing user-scoped PubSub topics and
  forwards broadcasts as channel pushes. Broadcast shapes are frozen during
  the LiveView/SvelteKit overlap (see the migration spec, invariant 1) — this
  module adapts, it never redefines payloads.

  Bridged topics:

    * `notifications:<user_id>` (`MagusWeb.Endpoint` broadcasts from the
      Notification resource's pub_sub) → pushed as `notification.<event>`,
      where `<event>` is the Ash action name (`create`, `mark_read`).
    * `files:files:<user_id>` (File pub_sub) → pushed as `file.<event>` with
      an id-only payload — the PubSub payload is the Ash notification (not
      JSON-encodable), and the SPA only needs a refetch hint.
    * `chat:folders:<user_id>` (Folder pub_sub) → pushed as `folder.<event>`
      with an id-only payload, same rationale.
    * `workbench:user:<user_id>` (shell PubSub) → the `{:workbench_user,
      :usage_changed}` signal is re-pushed as a data-less `usage.changed`
      hint after billable usage is recorded, so the SPA usage indicator
      refreshes live. The topic also carries other shell-internal messages
      (favorites changes, file-browser navigation); those are ignored.
  """
  use MagusWeb, :channel

  @impl true
  def join("user:" <> user_id, _payload, socket) do
    if user_id == socket.assigns.user_id do
      Magus.Endpoint.subscribe(Magus.Notifications.topic(user_id))
      Magus.Endpoint.subscribe("files:files:#{user_id}")
      Magus.Endpoint.subscribe("chat:folders:#{user_id}")

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user_id)
      )

      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "notifications:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "notification." <> event, payload)
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "files:files:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "file." <> event, %{"id" => record_id(payload)})
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "chat:folders:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "folder." <> event, %{"id" => record_id(payload)})
    {:noreply, socket}
  end

  # Shell usage signal: re-push as a data-less hint so the SPA refetches its
  # PAYG indicator via policy-gated RPC. Other shell-internal messages on this
  # topic (favorites, file-browser navigation) fall through to the catch-all.
  def handle_info({:workbench_user, :usage_changed}, socket) do
    push(socket, "usage.changed", %{})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Folder publishes transform to the record struct; File publishes the raw
  # Ash notification (record under :data). Either way only the id crosses
  # the wire — reads go through policy-gated RPC.
  defp record_id(%{data: %{id: id}}), do: id
  defp record_id(%{id: id}), do: id
  defp record_id(_payload), do: nil
end
