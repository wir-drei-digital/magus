defmodule MagusWeb.AgentsLive.AgentHelpers do
  @moduledoc """
  Activity-feed display helpers (type labels and badge/dot CSS classes, relative
  time) imported by the workbench agent view.

  (The agents LiveViews this was originally extracted for have been retired;
  only the functions still imported by `MagusWeb.Workbench.Resources.AgentView`
  remain.)
  """

  use MagusWeb, :html

  @doc "Human-readable label for an activity type atom."
  def activity_type_label(:triage_completed), do: gettext("Triage")
  def activity_type_label(:event_resolved), do: gettext("Resolved")
  def activity_type_label(:event_dismissed), do: gettext("Dismissed")
  def activity_type_label(:task_created), do: gettext("Task")
  def activity_type_label(:task_updated), do: gettext("Task")
  def activity_type_label(:task_completed), do: gettext("Done")
  def activity_type_label(:run_spawned), do: gettext("Run")
  def activity_type_label(:run_completed), do: gettext("Run")
  def activity_type_label(:run_failed), do: gettext("Error")
  def activity_type_label(:approval_requested), do: gettext("Approval")
  def activity_type_label(:response_sent), do: gettext("Response")
  def activity_type_label(:content_curated), do: gettext("Curation")
  def activity_type_label(:memory_updated), do: gettext("Memory")
  def activity_type_label(:error), do: gettext("Error")
  def activity_type_label(_), do: gettext("Activity")

  @doc "CSS dot colour class for an activity entry based on its type."
  def activity_dot_class(:error), do: "bg-error"
  def activity_dot_class(:run_failed), do: "bg-error"
  def activity_dot_class(:task_completed), do: "bg-success"
  def activity_dot_class(:run_completed), do: "bg-success"
  def activity_dot_class(:triage_completed), do: "bg-info"
  def activity_dot_class(:approval_requested), do: "bg-warning"
  def activity_dot_class(_), do: "bg-base-content/30"

  @doc "CSS badge class for an activity entry based on its type."
  def activity_badge_class(:error), do: "bg-error/10 text-error"
  def activity_badge_class(:run_failed), do: "bg-error/10 text-error"
  def activity_badge_class(:task_completed), do: "bg-success/10 text-success"
  def activity_badge_class(:run_completed), do: "bg-success/10 text-success"
  def activity_badge_class(:approval_requested), do: "bg-warning/10 text-warning"
  def activity_badge_class(:triage_completed), do: "bg-info/10 text-info"
  def activity_badge_class(_), do: "bg-base-200 text-base-content/60"

  @doc "Relative human-readable time string for a datetime."
  def relative_time(nil), do: ""

  def relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> gettext("just now")
      diff < 3600 -> ngettext("1 min ago", "%{count} min ago", div(diff, 60))
      diff < 86_400 -> ngettext("1 hr ago", "%{count} hr ago", div(diff, 3600))
      true -> ngettext("1 day ago", "%{count} days ago", div(diff, 86_400))
    end
  end
end
