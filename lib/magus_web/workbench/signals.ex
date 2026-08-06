defmodule MagusWeb.Workbench.Signals do
  @moduledoc """
  PubSub naming + broadcast helpers for user-scoped workbench signals.

  The classic LiveView workbench shell is retired; what remains is the
  user-scoped topic that bridges backend usage events to the SPA:
  `MagusWeb.UserChannel` subscribes to `workbench:user:<user_id>` and
  forwards `{:workbench_user, :usage_changed}` as a `usage.changed` push.
  """

  @doc """
  Topic for shell-level notifications scoped to a single user.
  """
  @spec workbench_user_topic(String.t()) :: String.t()
  def workbench_user_topic(user_id) when is_binary(user_id),
    do: "workbench:user:#{user_id}"

  @doc """
  Broadcasts that billable usage was recorded for a user so the client can
  refresh its pay-as-you-go usage indicator. Sent by
  `Magus.Agents.Persistence.UsageRecorder` after billable usage is recorded
  (live chat/image/video responses) or reconciled out of band.
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
