defmodule Magus.Checks.FilterChecksTest do
  @moduledoc """
  Regression tests for the FilterChecks that encode workspace-aware access
  rules. Each test exercises one branch of the OR chain so the FilterCheck
  cannot silently drift from the policies it replaced.
  """

  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Chat
  alias Magus.Files

  defp create_workspace(owner, slug) do
    {:ok, workspace} =
      Magus.Workspaces.create_workspace(%{name: "WS", slug: slug}, actor: owner)

    workspace
  end

  defp join_workspace(owner, workspace, member) do
    {:ok, invite} = Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)
    {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)
    :ok
  end

  defp create_file(user, attrs) do
    defaults = %{
      name: "filter-check-#{System.unique_integer([:positive])}.txt",
      type: :document,
      mime_type: "text/plain",
      file_size: 64,
      file_path: "/tmp/filter-check-#{System.unique_integer([:positive])}.txt",
      user_id: user.id
    }

    Files.File
    |> Ash.Changeset.for_create(:create_for_user, Map.merge(defaults, attrs))
    |> Ash.create(authorize?: false)
  end

  describe "ActorManagesFile (Files.File update/destroy)" do
    test "owner can destroy their own personal file" do
      user = generate(user())
      {:ok, file} = create_file(user, %{})

      assert :ok = Files.delete_file(file, actor: user)
    end

    test "workspace owner can destroy a member-created workspace file" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      workspace = create_workspace(owner, "amf-ws-owner")
      :ok = join_workspace(owner, workspace, member)

      {:ok, file} = create_file(member, %{workspace_id: workspace.id})

      assert :ok = Files.delete_file(file, actor: owner)
    end

    test "unrelated user cannot destroy a workspace file" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      workspace = create_workspace(owner, "amf-ws-deny")
      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      assert {:error, %Ash.Error.Forbidden{}} = Files.delete_file(file, actor: outsider)
    end

    test "regular member (non-owner) cannot destroy another member's workspace file" do
      owner = generate(user())
      member = generate(user())
      other_member = generate(user())
      ensure_workspace_plan(owner)

      workspace = create_workspace(owner, "amf-ws-member")
      :ok = join_workspace(owner, workspace, member)
      :ok = join_workspace(owner, workspace, other_member)

      {:ok, file} = create_file(member, %{workspace_id: workspace.id})

      assert {:error, %Ash.Error.Forbidden{}} = Files.delete_file(file, actor: other_member)
    end

    test "deactivated workspace admin cannot destroy workspace files via the admin branch" do
      # Exercises the `is_active == true` clause of ActorManagesFile.
      # Without it, a deactivated member who used to be an admin could still act.
      owner = generate(user())
      co_admin = generate(user())
      ensure_workspace_plan(owner)

      workspace = create_workspace(owner, "amf-deactivated")
      :ok = join_workspace(owner, workspace, co_admin)

      # Promote co_admin to :admin, then deactivate
      member_row =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Query.filter(workspace_id == ^workspace.id and user_id == ^co_admin.id)
        |> Ash.read_one!(authorize?: false)

      {:ok, promoted} =
        member_row
        |> Ash.Changeset.for_update(:change_role, %{role: :admin}, actor: owner)
        |> Ash.update()

      {:ok, _deactivated} =
        promoted
        |> Ash.Changeset.for_update(:deactivate, %{}, actor: owner)
        |> Ash.update()

      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      # co_admin still has the row with role=:admin but is_active=false
      assert {:error, %Ash.Error.Forbidden{}} = Files.delete_file(file, actor: co_admin)
    end
  end

  describe "ConversationVisibleToActor (pane state read)" do
    test "owner sees their own pane state" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, pane} =
        Chat.set_pane(conversation.id, user.id, :draft, Ash.UUIDv7.generate(), actor: user)

      require Ash.Query

      assert {:ok, [found]} =
               Magus.Chat.PaneState
               |> Ash.Query.filter(id == ^pane.id)
               |> Ash.read(actor: user)

      assert found.id == pane.id
    end

    test "unrelated user cannot see another user's pane state" do
      user = generate(user())
      outsider = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, pane} =
        Chat.set_pane(conversation.id, user.id, :draft, Ash.UUIDv7.generate(), actor: user)

      assert {:ok, []} =
               Magus.Chat.PaneState
               |> Ash.Query.filter(id == ^pane.id)
               |> Ash.read(actor: outsider)
    end

    test "invited-but-not-accepted conversation member cannot see pane state" do
      # Exercises the `not is_nil(accepted_at)` clause on the member branch of
      # ConversationVisibleToActor. Without it, anyone with a row in
      # conversation_members — including still-pending invites — would be able
      # to read the conversation's per-user pane state.
      owner = generate(user())
      invitee = generate(user())
      conversation = generate(conversation(actor: owner))

      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, invitee.id, authorize?: false)

      # Accept so the invitee can set a pane state, then revert accepted_at
      # to simulate an invite that is still pending (or was revoked) — the
      # FilterCheck's `not is_nil(accepted_at)` branch is what we exercise.
      {:ok, accepted} =
        membership
        |> Ash.Changeset.for_update(:accept_invitation, %{})
        |> Ash.update(authorize?: false)

      {:ok, pane} =
        Chat.set_pane(conversation.id, invitee.id, :draft, Ash.UUIDv7.generate(), actor: invitee)

      {:ok, _reverted} =
        accepted
        |> Ash.Changeset.for_update(:change_role, %{})
        |> Ash.Changeset.force_change_attribute(:accepted_at, nil)
        |> Ash.update(authorize?: false)

      # Even though invitee owns the pane row, the conversation-visibility
      # branch rejects because accepted_at is nil and they don't own the
      # conversation.
      assert {:ok, []} =
               Magus.Chat.PaneState
               |> Ash.Query.filter(id == ^pane.id)
               |> Ash.read(actor: invitee)
    end
  end
end
