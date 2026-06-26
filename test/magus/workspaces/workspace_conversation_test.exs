defmodule Magus.Workspaces.WorkspaceConversationTest do
  use Magus.ResourceCase, async: true

  describe "workspace conversations" do
    test "can create a conversation in a workspace" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-conv"},
          actor: owner
        )

      {:ok, conversation} =
        Magus.Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      assert conversation.workspace_id == workspace.id
    end

    test "non-member cannot create a conversation in another workspace" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-conv-deny"},
          actor: owner
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.create_conversation(
                 %{workspace_id: workspace.id},
                 actor: outsider
               )
    end

    test "workspace member can read shared workspace conversations" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-shared"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, conversation} =
        Magus.Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the new read policy.
      {:ok, conversation} =
        Magus.Chat.share_conversation_to_team(conversation, actor: owner)

      assert {:ok, found} =
               Magus.Chat.get_conversation(conversation.id, actor: member)

      assert found.id == conversation.id
    end

    test "workspace member cannot read private workspace conversations of others" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-priv"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, conversation} =
        Magus.Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Chat.get_conversation(conversation.id, actor: member)
    end

    test "personal conversations remain unaffected" do
      user = generate(user())

      {:ok, conversation} =
        Magus.Chat.create_conversation(%{}, actor: user)

      assert conversation.workspace_id == nil
      assert {:ok, _} = Magus.Chat.get_conversation(conversation.id, actor: user)
    end

    test "workspace_conversations lists shared conversations to other members" do
      # Regression test: a `exists(ResourceAccess, ...)` clause in the action
      # filter caused Ash to apply ResourceAccess's read policy to AccessCheck's
      # subquery as well, restricting visible grants to grantee_type=:user and
      # hiding workspace-targeted grants from non-creators. See conversation.ex
      # `:workspace_conversations`.
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "List Test", slug: "list-shared-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, owner_shared} =
        Magus.Chat.create_conversation(%{workspace_id: workspace.id}, actor: owner)

      {:ok, owner_shared} =
        Magus.Chat.share_conversation_to_team(owner_shared, actor: owner)

      {:ok, owner_private} =
        Magus.Chat.create_conversation(%{workspace_id: workspace.id}, actor: owner)

      {:ok, member_private} =
        Magus.Chat.create_conversation(%{workspace_id: workspace.id}, actor: member)

      member_visible =
        Magus.Chat.workspace_conversations!(workspace.id, actor: member)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert MapSet.member?(member_visible, owner_shared.id),
             "member should see owner's shared conversation"

      assert MapSet.member?(member_visible, member_private.id),
             "member should see their own conversation"

      refute MapSet.member?(member_visible, owner_private.id),
             "member should not see owner's private conversation"

      owner_visible =
        Magus.Chat.workspace_conversations!(workspace.id, actor: owner)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert MapSet.member?(owner_visible, owner_shared.id)
      assert MapSet.member?(owner_visible, owner_private.id)

      refute MapSet.member?(owner_visible, member_private.id),
             "owner should not see member's private conversation"
    end
  end
end
