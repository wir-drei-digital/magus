defmodule MagusWeb.UserSocket do
  @moduledoc """
  WebSocket entry point for the SvelteKit workbench (and future native/CLI
  clients). Carries Phoenix Channels that bridge existing PubSub topics and,
  later, channel-based RPC.

  Authentication is token-based: the client fetches a `Phoenix.Token` from
  `GET /rpc/socket-token` (session-authenticated) and passes it as a connect
  param. This keeps the socket independent of cookie semantics so the same
  path works for Capacitor/CLI clients.
  """
  use Phoenix.Socket

  alias MagusWeb.Rpc.RpcController

  channel "user:*", MagusWeb.UserChannel
  channel "conversation:*", MagusWeb.ConversationChannel
  channel "workspace:*", MagusWeb.WorkspaceChannel
  channel "agent:*", MagusWeb.AgentChannel
  channel "brain_updates:*", MagusWeb.BrainChannel
  channel "viewers:*", MagusWeb.PresenceChannel
  channel "conversation_presence:*", MagusWeb.ConversationPresenceChannel
  channel "plan_tasks:*", MagusWeb.TaskChannel
  channel "brain_tasks:*", MagusWeb.TaskChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(socket, RpcController.socket_token_salt(), token,
             max_age: RpcController.socket_token_max_age()
           ),
         {:ok, user} <- Magus.Accounts.get_user(user_id) do
      {:ok, socket |> assign(:user_id, user_id) |> assign(:current_user, user)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Lets us disconnect all sockets for a user via
  # Magus.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{}).
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
