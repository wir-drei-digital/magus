defmodule Magus.Cli.ConnectionRegistry do
  @moduledoc """
  Registry of live `magus chat` WebSocket handler processes, keyed by the
  AUTHENTICATED user id — never by anything a client sends. Reverse-tunnel
  tools (`Magus.Agents.Tools.Remote.*`) route via `lookup/1` with the
  server-side `acting_user_id` from the tool context, so a turn can only ever
  reach a connection owned by the user who triggered it.

  Keys are `:duplicate`: a user may briefly hold several connections (a
  reconnect racing a half-open stale socket, or two terminals). `lookup/1`
  resolves to the most recently registered connection that is still alive
  (last one wins); older connections stay usable for chat but stop receiving
  tunnel calls. Entries are removed automatically when their process dies.
  """

  def child_spec(_arg) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Registers the calling process as a CLI connection for `user_id`."
  @spec register(String.t()) :: :ok
  def register(user_id) when is_binary(user_id) do
    # The value orders same-user registrations; unique_integer(:monotonic) is
    # strictly increasing per node, so "most recent" is never ambiguous.
    {:ok, _} = Registry.register(__MODULE__, user_id, System.unique_integer([:monotonic]))
    :ok
  end

  @doc "The most recently registered live connection for `user_id`, or nil."
  @spec lookup(String.t() | nil) :: pid() | nil
  def lookup(user_id) when is_binary(user_id) do
    __MODULE__
    |> Registry.lookup(user_id)
    |> Enum.sort_by(fn {_pid, registered_at} -> registered_at end, :desc)
    |> Enum.find_value(fn {pid, _} -> Process.alive?(pid) && pid end)
  end

  def lookup(_), do: nil
end
