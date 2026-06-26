defmodule Magus.Workspaces.DeactivatedAccessTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  defp create_file(user, attrs) do
    defaults = %{
      name: "test-file.txt",
      type: :document,
      mime_type: "text/plain",
      file_size: 1024,
      file_path: "/tmp/test-file-#{System.unique_integer([:positive])}.txt",
      user_id: user.id
    }

    Magus.Files.File
    |> Ash.Changeset.for_create(:create_for_user, Map.merge(defaults, attrs))
    |> Ash.create(authorize?: false)
  end

  describe "deactivated members lose access to shared workspace resources" do
    setup do
      owner = generate(user())
      member_user = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-deact-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member_user.email, actor: owner)

      {:ok, membership} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member_user)

      %{owner: owner, member_user: member_user, workspace: workspace, membership: membership}
    end

    test "deactivated member cannot read shared workspace conversation",
         %{owner: owner, member_user: member_user, workspace: workspace, membership: membership} do
      {:ok, conversation} =
        Magus.Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy.
      {:ok, _} = Magus.Chat.share_conversation_to_team(conversation, actor: owner)

      # Sanity: member can read it before deactivation
      assert {:ok, _} = Magus.Chat.get_conversation(conversation.id, actor: member_user)

      {:ok, _} = Magus.Workspaces.deactivate_member(membership, actor: owner)

      # Deactivated member should no longer read it
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Chat.get_conversation(conversation.id, actor: member_user)
    end

    test "deactivated member cannot read shared workspace file",
         %{owner: owner, member_user: member_user, workspace: workspace, membership: membership} do
      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      # Path B: members need an explicit workspace-level grant to see a file.
      {:ok, _} =
        Magus.Workspaces.ResourceAccess
        |> Ash.Changeset.for_create(
          :grant,
          %{
            resource_type: :file,
            resource_id: file.id,
            grantee_type: :workspace,
            grantee_id: workspace.id,
            role: :viewer
          },
          actor: owner
        )
        |> Ash.create()

      # Sanity: member can read it before deactivation
      assert {:ok, _} = Magus.Files.get_file(file.id, actor: member_user)

      {:ok, _} = Magus.Workspaces.deactivate_member(membership, actor: owner)

      # Deactivated member should no longer read it
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Files.get_file(file.id, actor: member_user)
    end

    test "deactivated member cannot read shared workspace prompt",
         %{owner: owner, member_user: member_user, workspace: workspace, membership: membership} do
      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "Body", type: :user, workspace_id: workspace.id},
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy.
      {:ok, _} = Magus.Library.share_prompt_to_team(prompt, actor: owner)

      # Sanity: member can read it before deactivation
      assert {:ok, _} = Magus.Library.get_prompt(prompt.id, actor: member_user)

      {:ok, _} = Magus.Workspaces.deactivate_member(membership, actor: owner)

      # Deactivated member should no longer read it
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Library.get_prompt(prompt.id, actor: member_user)
    end

    test "deactivated member cannot read shared workspace custom agent",
         %{owner: owner, member_user: member_user, workspace: workspace, membership: membership} do
      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "A", workspace_id: workspace.id},
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy.
      {:ok, _} = Magus.Agents.share_custom_agent_to_team(agent, actor: owner)

      # Sanity: member can read it before deactivation
      assert {:ok, _} = Magus.Agents.get_custom_agent(agent.id, actor: member_user)

      {:ok, _} = Magus.Workspaces.deactivate_member(membership, actor: owner)

      # Deactivated member should no longer read it
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Agents.get_custom_agent(agent.id, actor: member_user)
    end
  end
end
