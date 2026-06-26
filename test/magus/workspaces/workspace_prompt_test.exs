defmodule Magus.Workspaces.WorkspacePromptTest do
  use Magus.ResourceCase, async: true

  describe "workspace prompts" do
    test "can create a prompt in a workspace" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-ws"},
          actor: owner
        )

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Workspace Prompt",
            content: "A prompt for the workspace",
            type: :user,
            workspace_id: workspace.id
          },
          actor: owner
        )

      assert prompt.workspace_id == workspace.id
    end

    test "non-member cannot create a prompt in another workspace" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-create-deny"},
          actor: owner
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Library.create_prompt(
                 %{
                   name: "Workspace Prompt",
                   content: "forbidden",
                   type: :user,
                   workspace_id: workspace.id
                 },
                 actor: outsider
               )
    end

    test "workspace member can read workspace prompts once shared to team" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-read"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Shared Prompt",
            content: "Shared content",
            type: :system,
            workspace_id: workspace.id
          },
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy.
      {:ok, _} = Magus.Library.share_prompt_to_team(prompt, actor: owner)

      assert {:ok, found} = Magus.Library.get_prompt(prompt.id, actor: member)
      assert found.id == prompt.id
    end

    test "non-member cannot read workspace prompts" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-noaccess"},
          actor: owner
        )

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Private Prompt",
            content: "Private content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: owner
        )

      # Owner can read it
      assert {:ok, _} = Magus.Library.get_prompt(prompt.id, actor: owner)

      # Non-member cannot
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Library.get_prompt(prompt.id, actor: outsider)
    end

    test "personal prompts remain unaffected" do
      user = generate(user())

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "Personal Prompt", content: "My content", type: :user},
          actor: user
        )

      assert prompt.workspace_id == nil
      assert {:ok, _} = Magus.Library.get_prompt(prompt.id, actor: user)
    end

    test "my_prompts returns only personal prompts; workspace_prompts lists workspace-scoped prompts" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-myprompts"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      # Owner creates a workspace prompt and shares it to the team
      {:ok, ws_prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Team Prompt",
            content: "Team content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: owner
        )

      {:ok, _} = Magus.Library.share_prompt_to_team(ws_prompt, actor: owner)

      # Member creates a personal prompt
      {:ok, personal_prompt} =
        Magus.Library.create_prompt(
          %{name: "My Prompt", content: "My content", type: :user},
          actor: member
        )

      # Under Path B, my_prompts is strictly personal (workspace_id IS NULL).
      {:ok, my_prompts} = Magus.Library.my_prompts(actor: member)
      my_ids = Enum.map(my_prompts, & &1.id)

      assert personal_prompt.id in my_ids
      refute ws_prompt.id in my_ids

      # Workspace-scoped prompts are listed via :workspace_prompts and governed
      # by the standard workspace_scoped_policies (creator OR grants).
      {:ok, ws_prompts} = Magus.Library.workspace_prompts(workspace.id, actor: member)
      ws_ids = Enum.map(ws_prompts, & &1.id)
      assert ws_prompt.id in ws_ids
    end

    test "workspace owner can update a member-created workspace prompt" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-owner-manage"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Member Prompt",
            content: "Team content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: member
        )

      assert {:ok, updated} =
               Magus.Library.update_prompt(prompt, %{name: "Owner Updated"}, actor: owner)

      assert updated.name == "Owner Updated"
    end

    test "deactivated member cannot read workspace prompts" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-prompt-deactivated"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, membership} =
        Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{
            name: "Team Prompt",
            content: "Team content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy.
      {:ok, _} = Magus.Library.share_prompt_to_team(prompt, actor: owner)

      # Member can read before deactivation
      assert {:ok, _} = Magus.Library.get_prompt(prompt.id, actor: member)

      # Deactivate the member
      {:ok, _} = Magus.Workspaces.deactivate_member(membership, actor: owner)

      # Deactivated member can no longer read workspace prompts
      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Library.get_prompt(prompt.id, actor: member)
    end
  end
end
