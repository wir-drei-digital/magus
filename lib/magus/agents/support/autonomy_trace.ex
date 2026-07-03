defmodule Magus.Agents.Support.AutonomyTrace do
  @moduledoc """
  Best-effort AgentActivityLog writes from autonomy machinery (scheduler,
  urgent wakes, sweeps, recovery). Never raises; nil ids no-op — silent
  branches must stay observable without becoming fragile.
  """

  require Logger

  @doc """
  Writes an `AgentActivityLog` entry for a silent autonomy branch.

  `agent_id` and `user_id` are the `CustomAgent` and owning `User` ids. If
  either is `nil` this is a no-op (some autonomy call sites — e.g. non-agent
  `AgentRun`s — have nothing to attribute the entry to). Never raises: any
  failure is logged and swallowed so a broken trace write can't break the
  autonomy path it's observing.
  """
  def log(agent_id, user_id, activity_type, summary, metadata \\ %{})

  def log(nil, _user_id, _activity_type, _summary, _metadata), do: :ok
  def log(_agent_id, nil, _activity_type, _summary, _metadata), do: :ok

  def log(agent_id, user_id, activity_type, summary, metadata) do
    with {:ok, user} <- Ash.get(Magus.Accounts.User, user_id, authorize?: false) do
      case Magus.Agents.create_activity_log(
             %{
               agent_id: agent_id,
               activity_type: activity_type,
               summary: summary,
               details: metadata
             },
             actor: user,
             authorize?: false
           ) do
        {:ok, _log} ->
          :ok

        {:error, reason} ->
          Logger.warning("AutonomyTrace: log failed (#{activity_type}): #{inspect(reason)}")
          :ok
      end
    else
      {:error, reason} ->
        Logger.warning(
          "AutonomyTrace: could not resolve user #{user_id} (#{activity_type}): #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("AutonomyTrace: log crashed (#{activity_type}): #{Exception.message(e)}")
      :ok
  end
end
