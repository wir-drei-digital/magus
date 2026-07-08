defmodule Magus.Agents.Support.TurnKeepalive do
  @moduledoc """
  Liveness ticker for long-running agent work.

  While active it periodically touches `Magus.Agents.RunLiveness` (so
  CleanupStale never falsely times out a working AgentRun) and broadcasts
  `turn.keepalive` on the conversation topic (so clients keep their busy
  state armed through silent phases: long tool calls, unstreamed thinking,
  media generation).

  Lifetime is double-guarded: the ticker monitors a watched process (the
  ReAct coordinator, a media-generation task, or whatever process owns the
  work) and dies on its DOWN, and callers doing synchronous work in a
  long-lived process (e.g. image generation inside the agent server) stop it
  explicitly via `stop/1`. Tick errors are swallowed: liveness reporting
  must never break the work it reports on.
  """

  require Logger

  @doc """
  Starts a keepalive ticker for the conversation.

  Returns the ticker pid, or `nil` when the conversation id is missing or
  the configured interval (`config :magus, :agents, :turn_keepalive_interval_ms`)
  is not a positive integer.

  ## Options

    * `:watch` — process whose death ends the ticker (default: the caller).
  """
  @spec start(String.t() | nil, keyword()) :: pid() | nil
  def start(conversation_id, opts \\ [])

  def start(conversation_id, opts) when is_binary(conversation_id) do
    interval = interval_ms()
    watch = Keyword.get(opts, :watch, self())

    if is_integer(interval) and interval > 0 and is_pid(watch) do
      spawn(fn ->
        mon_ref = Process.monitor(watch)
        loop(conversation_id, interval, mon_ref)
      end)
    end
  end

  def start(_conversation_id, _opts), do: nil

  @doc "Stops a ticker returned by `start/2`. Accepts nil for convenience."
  @spec stop(pid() | nil) :: :ok
  def stop(ticker) when is_pid(ticker) do
    send(ticker, :stop)
    :ok
  end

  def stop(_ticker), do: :ok

  defp loop(conversation_id, interval, mon_ref) do
    receive do
      :stop ->
        :ok

      {:DOWN, ^mon_ref, :process, _pid, _reason} ->
        :ok
    after
      interval ->
        tick(conversation_id)
        loop(conversation_id, interval, mon_ref)
    end
  end

  defp tick(conversation_id) do
    Magus.Agents.RunLiveness.touch(conversation_id)
    Magus.Agents.Signals.turn_keepalive(conversation_id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp interval_ms do
    :magus
    |> Application.get_env(:agents, [])
    |> Keyword.get(:turn_keepalive_interval_ms, 15_000)
  end
end
