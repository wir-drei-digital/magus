defmodule Magus.Library.PromptWorkspaceTest do
  @moduledoc """
  Tests for the generic workspace-scoped policy on `Magus.Library.Prompt`
  backed by `Magus.Workspaces.ResourceAccess` grants. Also covers the
  `is_public` read extra, `share_to_team` / `unshare_from_team` grant
  sync, and destroy grant cleanup.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Library
  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  require Ash.Query

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} =
      Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)

    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  defp grants_for(prompt) do
    ResourceAccess
    |> Ash.Query.for_read(:for_resource, %{resource_type: :prompt, resource_id: prompt.id})
    |> Ash.read!(authorize?: false)
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-prompt-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, stranger: stranger, workspace: workspace}
    end

    test "creator can read their own workspace prompt", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Mine",
            content: "Private content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      assert {:ok, _} = Library.get_prompt(prompt.id, actor: creator)
    end

    test "private workspace prompt (no grant) is hidden from active members", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Private",
            content: "Private content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Library.get_prompt(prompt.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read the prompt", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Shared",
            content: "Shared content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :prompt,
          resource_id: prompt.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Library.get_prompt(prompt.id, actor: stranger)
    end

    test "stranger (non-member) cannot see prompt even with workspace grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Granted",
            content: "Granted content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      _grant =
        grant!(%{
          resource_type: :prompt,
          resource_id: prompt.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:error, _} = Library.get_prompt(prompt.id, actor: stranger)
    end
  end

  describe "is_public read extra" do
    test "a public prompt is readable by a stranger (non-member)" do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-public-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "To Publish",
            content: "Content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      # Stranger cannot read while private.
      assert {:error, _} = Library.get_prompt(prompt.id, actor: stranger)

      {:ok, published} = Library.publish_prompt(prompt, %{is_public: true}, actor: creator)
      assert published.is_public == true

      # Now readable by anyone via is_public extra.
      assert {:ok, _} = Library.get_prompt(prompt.id, actor: stranger)
    end

    test "a personal public prompt is readable by any user" do
      creator = generate(user())
      stranger = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{name: "Personal Public", content: "Content", type: :user},
          actor: creator
        )

      assert {:error, _} = Library.get_prompt(prompt.id, actor: stranger)

      {:ok, _} = Library.publish_prompt(prompt, %{is_public: true}, actor: creator)

      assert {:ok, _} = Library.get_prompt(prompt.id, actor: stranger)
    end
  end

  describe "share_to_team / unshare_from_team grant sync" do
    setup do
      creator = generate(user())
      member_user = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-pshare-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      _ = add_active_member(workspace, creator, member_user)

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "For Sharing",
            content: "Content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      %{
        creator: creator,
        member_user: member_user,
        workspace: workspace,
        prompt: prompt
      }
    end

    test "share_to_team creates a workspace-level grant", %{
      creator: creator,
      workspace: workspace,
      prompt: prompt
    } do
      assert grants_for(prompt) == []

      {:ok, _shared} = Library.share_prompt_to_team(prompt, actor: creator)

      grants = grants_for(prompt)
      assert length(grants) == 1

      [g] = grants
      assert g.resource_type == :prompt
      assert g.resource_id == prompt.id
      assert g.grantee_type == :workspace
      assert g.grantee_id == workspace.id
      assert g.role == :viewer
    end

    test "share_to_team is idempotent when run twice", %{
      creator: creator,
      prompt: prompt
    } do
      {:ok, _} = Library.share_prompt_to_team(prompt, actor: creator)
      {:ok, _} = Library.share_prompt_to_team(prompt, actor: creator)

      assert length(grants_for(prompt)) == 1
    end

    test "shared prompt is readable by active workspace member via grant", %{
      creator: creator,
      member_user: member_user,
      prompt: prompt
    } do
      # Not readable before sharing.
      assert {:error, _} = Library.get_prompt(prompt.id, actor: member_user)

      {:ok, _} = Library.share_prompt_to_team(prompt, actor: creator)

      assert {:ok, _} = Library.get_prompt(prompt.id, actor: member_user)
    end

    test "unshare_from_team removes the workspace grant", %{
      creator: creator,
      member_user: member_user,
      prompt: prompt
    } do
      {:ok, _} = Library.share_prompt_to_team(prompt, actor: creator)
      assert length(grants_for(prompt)) == 1
      assert {:ok, _} = Library.get_prompt(prompt.id, actor: member_user)

      {:ok, _} = Library.unshare_prompt_from_team(prompt, actor: creator)

      assert grants_for(prompt) == []
      assert {:error, _} = Library.get_prompt(prompt.id, actor: member_user)
    end
  end

  describe "destroy grant cleanup" do
    test "destroying a prompt cleans up its ResourceAccess grants" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-pdestroy-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "To Destroy",
            content: "Content",
            type: :user,
            workspace_id: workspace.id
          },
          actor: creator
        )

      {:ok, _} = Library.share_prompt_to_team(prompt, actor: creator)
      assert length(grants_for(prompt)) == 1

      :ok = Library.destroy_prompt(prompt, actor: creator)

      assert grants_for(prompt) == []
    end
  end
end
