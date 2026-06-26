defmodule Magus.Agents.CustomAgentAttachment.Changes.RevokeAgentAccess do
  @moduledoc """
  Before destroying an attachment, revoke the corresponding ResourceAccess
  grant that paired the agent to the file. Mirrors GrantAgentAccess.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn cs ->
      attachment = cs.data

      Magus.Workspaces.ResourceAccess
      |> Ash.Query.filter(
        resource_type == :file and
          resource_id == ^attachment.file_id and
          grantee_type == :custom_agent and
          grantee_id == ^attachment.custom_agent_id
      )
      |> Ash.bulk_destroy!(:revoke, %{}, authorize?: false, return_errors?: true)

      cs
    end)
  end
end
