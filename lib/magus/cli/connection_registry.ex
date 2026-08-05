defmodule Magus.Cli.ConnectionRegistry do
  @moduledoc """
  Registry of live `magus chat` WebSocket handler processes, keyed by the
  AUTHENTICATED user id — never by anything a client sends. Reverse-tunnel
  tools (`Magus.Agents.Tools.Remote.*`) route via `lookup/2` with the
  server-side `acting_user_id` + `conversation_id` from the tool context, so a
  turn can only ever reach a connection owned by the user who triggered it.

  Keys are `:duplicate`: a user may hold several connections (a reconnect
  racing a half-open stale socket, or two machines). `lookup/2` prefers the
  most recent live connection attached to the turn's conversation — so with
  `magus chat` open on two machines, each conversation's reads go to the
  machine that is driving it — and falls back to the most recent live
  connection overall when none matches. Entries are removed automatically
  when their process dies.

  Node-local by design (Elixir's `Registry` does not replicate): the socket
  and the agent turn must run on the same node. Under clustering
  (DNS_CLUSTER_QUERY) this needs a distributed registry (`:pg` or
  Phoenix.Tracker) — a known follow-up, not silently supported.
  """

  def child_spec(_arg) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Registers the calling process as `user_id`'s CLI connection for `conversation_id`."
  @spec register(String.t(), String.t()) :: :ok
  def register(user_id, conversation_id) when is_binary(user_id) do
    # The first tuple element orders same-user registrations;
    # unique_integer(:monotonic) is strictly increasing per node, so "most
    # recent" is never ambiguous.
    {:ok, _} =
      Registry.register(
        __MODULE__,
        user_id,
        {System.unique_integer([:monotonic]), conversation_id}
      )

    :ok
  end

  @doc """
  The live connection serving `conversation_id` for `user_id`; falls back to
  the user's most recently registered live connection, or nil.
  """
  @spec lookup(String.t() | nil, String.t() | nil) :: pid() | nil
  def lookup(user_id, conversation_id) when is_binary(user_id) do
    entries =
      __MODULE__
      |> Registry.lookup(user_id)
      |> Enum.sort_by(fn {_pid, {order, _conv}} -> order end, :desc)
      |> Enum.filter(fn {pid, _} -> Process.alive?(pid) end)

    conversation_match =
      is_binary(conversation_id) &&
        Enum.find_value(entries, fn {pid, {_order, conv}} -> conv == conversation_id && pid end)

    case {conversation_match, entries} do
      {pid, _} when is_pid(pid) -> pid
      {_, [{pid, _} | _]} -> pid
      {_, []} -> nil
    end
  end

  def lookup(_, _), do: nil
end
