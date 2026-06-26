defmodule Magus.Agents.CustomAgentAttachment.Changes.GrantAgentAccess do
  @moduledoc """
  After an attachment is created, grant the parent custom agent :viewer
  access on the attached file via Magus.Workspaces.ResourceAccess. This
  is what makes "access flows through the agent" work: anyone who can
  use the agent transparently inherits read access on attached files
  through the agent identity at runtime.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.after_action(changeset, fn _cs, attachment ->
      _ =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :file,
            resource_id: attachment.file_id,
            grantee_type: :custom_agent,
            grantee_id: attachment.custom_agent_id,
            role: :viewer
          },
          authorize?: false
        )

      {:ok, attachment}
    end)
  end
end
