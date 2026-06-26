defmodule Magus.Knowledge.KnowledgeSourceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Knowledge

  describe "create_source" do
    test "creates a personal knowledge source" do
      user = generate(user())

      {:ok, source} =
        Knowledge.create_source(
          %{
            name: "My Google Drive",
            provider: :google_drive,
            auth_config: %{"access_token" => "test_token"}
          },
          actor: user
        )

      assert source.name == "My Google Drive"
      assert source.provider == :google_drive
      assert source.status == :pending
      assert source.user_id == user.id
      assert source.workspace_id == nil
    end

    test "creates a workspace-scoped knowledge source" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      {:ok, source} =
        Knowledge.create_source(
          %{
            name: "Team Notion",
            provider: :notion,
            auth_config: %{"api_key" => "test_key"},
            workspace_id: workspace.id
          },
          actor: user
        )

      assert source.workspace_id == workspace.id
    end

    test "non-member cannot create a workspace knowledge source in another workspace" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)
      workspace = generate(workspace(actor: owner))

      assert {:error, %Ash.Error.Forbidden{}} =
               Knowledge.create_source(
                 %{
                   name: "Forbidden Source",
                   provider: :notion,
                   auth_config: %{"api_key" => "test_key"},
                   workspace_id: workspace.id
                 },
                 actor: outsider
               )
    end

    test "rejects invalid provider" do
      user = generate(user())

      assert {:error, _} =
               Knowledge.create_source(
                 %{
                   name: "Bad Provider",
                   provider: :invalid,
                   auth_config: %{}
                 },
                 actor: user
               )
    end
  end

  describe "update_source_status" do
    test "transitions source to active" do
      user = generate(user())

      {:ok, source} =
        Knowledge.create_source(
          %{name: "Test", provider: :google_drive, auth_config: %{"token" => "t"}},
          actor: user
        )

      {:ok, updated} = Knowledge.update_source_status(source, %{status: :active}, actor: user)
      assert updated.status == :active
    end

    test "stores error message on error status" do
      user = generate(user())

      {:ok, source} =
        Knowledge.create_source(
          %{name: "Test", provider: :google_drive, auth_config: %{"token" => "t"}},
          actor: user
        )

      {:ok, updated} =
        Knowledge.update_source_status(
          source,
          %{status: :error, last_error: "Token expired"},
          actor: user
        )

      assert updated.status == :error
      assert updated.last_error == "Token expired"
    end
  end

  describe "workspace reads" do
    test "workspace member can list workspace-scoped sources" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)
      workspace = generate(workspace(actor: owner))

      {:ok, invite} = Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)
      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, source} =
        Knowledge.create_source(
          %{
            name: "Team Notion",
            provider: :notion,
            auth_config: %{"api_key" => "test_key"},
            workspace_id: workspace.id
          },
          actor: owner
        )

      assert {:ok, sources} = Knowledge.list_sources_for_workspace(workspace.id, actor: member)
      assert Enum.any?(sources, &(&1.id == source.id))
    end
  end
end
