defmodule Magus.Skills.Approval do
  @moduledoc """
  First-run approval for bundled skills. Requesting creates a notification and
  an action-card message; the user's "Approve skill: <id>" reply is recorded
  onto the conversation by the approval matcher. Materialization gates on
  `approved?/2`.
  """

  @doc "True when the skill is recorded as approved on the conversation."
  def approved?(conversation, skill_id) do
    skill_id in (Map.get(conversation, :approved_skill_ids) || [])
  end

  @doc """
  The phrase the user's approval reply must start with for this skill. Kept in
  one place so the request action-card and the matcher agree.
  """
  def approve_phrase(skill_id), do: "Approve skill: #{skill_id}"

  @doc "Ask the user to approve running a skill's bundled code."
  def request(conversation_id, skill, user_id) do
    question = "Allow the skill \"#{skill.name}\" to run its bundled code in the sandbox?"

    Magus.Notifications.create_notification(
      %{
        user_id: user_id,
        notification_type: :approval_request,
        title: "Skill approval needed",
        body: question,
        target_conversation_id: conversation_id,
        metadata: %{skill_id: skill.id, options: ["Approve", "Reject"]}
      },
      authorize?: false
    )

    :ok
  end
end
