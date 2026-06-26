defmodule Magus.Workspaces.WorkspaceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Workspaces

  describe "create_workspace" do
    test "creates workspace with valid attributes" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Acme Corp", slug: "acme-corp"}, actor: user)

      assert workspace.name == "Acme Corp"
      assert workspace.slug == "acme-corp"
    end

    test "rejects workspace without name" do
      user = generate(user())
      ensure_workspace_plan(user)

      assert {:error, %Ash.Error.Invalid{}} =
               Workspaces.create_workspace(%{slug: "no-name"}, actor: user)
    end

    test "rejects duplicate slug" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, _} =
        Workspaces.create_workspace(%{name: "First", slug: "unique-slug"}, actor: user)

      assert {:error, %Ash.Error.Invalid{}} =
               Workspaces.create_workspace(%{name: "Second", slug: "unique-slug"}, actor: user)
    end
  end

  describe "get_workspace" do
    test "returns workspace by id" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test WS", slug: "test-ws"}, actor: user)

      {:ok, found} = Workspaces.get_workspace(workspace.id, authorize?: false)
      assert found.id == workspace.id
      assert found.name == "Test WS"
    end
  end

  describe "defaults" do
    test "is_active defaults to true" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Active WS", slug: "active-ws"}, actor: user)

      assert workspace.is_active == true
    end
  end
end
