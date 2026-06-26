defmodule Magus.SuperBrain.AccessibleGraphsTest do
  use Magus.ResourceCase, async: true

  alias Magus.SuperBrain.AccessibleGraphs

  describe "for_actor/2" do
    test "user with no workspaces gets personal graphs only" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: nil)

      assert "brain:#{brain.id}" in graphs
      assert "memories:user:#{user.id}" in graphs
      assert "files:user:#{user.id}" in graphs
      assert "drafts:user:#{user.id}" in graphs

      refute Enum.any?(graphs, &String.starts_with?(&1, "memories:workspace:"))
      refute Enum.any?(graphs, &String.starts_with?(&1, "files:workspace:"))
    end

    test "user in a workspace sees workspace graphs in workspace context" do
      user = generate(user())
      ws = generate(workspace(actor: user))
      ws_brain = generate(brain(user_id: user.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: ws.id)

      assert "brain:#{ws_brain.id}" in graphs
      assert "memories:workspace:#{ws.id}" in graphs
      assert "files:workspace:#{ws.id}" in graphs
    end

    test "user cannot see brains owned by other users in the workspace unless granted" do
      user_a = generate(user())
      user_b = generate(user())
      ws = generate(workspace(actor: user_a))
      _membership = workspace_member(user_id: user_b.id, workspace_id: ws.id)

      private_brain = generate(brain(user_id: user_b.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(user_a, workspace_context: ws.id)

      refute "brain:#{private_brain.id}" in graphs
    end

    test "workspace context without active membership returns no workspace graphs" do
      user = generate(user())
      other_user = generate(user())
      ws = generate(workspace(actor: other_user))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: ws.id)

      refute "memories:workspace:#{ws.id}" in graphs
      refute "files:workspace:#{ws.id}" in graphs
    end
  end

  describe "super_graph_for/2" do
    test "returns the personal super graph for nil workspace" do
      user = generate(user())

      assert Magus.SuperBrain.AccessibleGraphs.super_graph_for(user, workspace_context: nil) ==
               "super:user:#{user.id}"
    end

    test "returns the workspace super graph for a workspace context" do
      user = generate(user())
      workspace = generate(workspace(actor: user))

      assert Magus.SuperBrain.AccessibleGraphs.super_graph_for(user,
               workspace_context: workspace.id
             ) == "super:workspace:#{workspace.id}:#{user.id}"
    end
  end

  describe "accessors_of/1" do
    test "personal memory graph maps to the owner" do
      uid = Ash.UUID.generate()

      assert Magus.SuperBrain.AccessibleGraphs.accessors_of("memories:user:#{uid}") ==
               [%{type: :user, user_id: uid, workspace_id: nil}]
    end

    test "personal files graph maps to the owner" do
      uid = Ash.UUID.generate()

      assert Magus.SuperBrain.AccessibleGraphs.accessors_of("files:user:#{uid}") ==
               [%{type: :user, user_id: uid, workspace_id: nil}]
    end

    test "personal drafts graph maps to the owner" do
      uid = Ash.UUID.generate()

      assert Magus.SuperBrain.AccessibleGraphs.accessors_of("drafts:user:#{uid}") ==
               [%{type: :user, user_id: uid, workspace_id: nil}]
    end

    test "workspace memory graph maps to all active members" do
      user_a = generate(user())
      user_b = generate(user())
      workspace = generate(workspace(actor: user_a))
      _ = workspace_member(user_id: user_b.id, workspace_id: workspace.id, role: :member)

      accessors =
        Magus.SuperBrain.AccessibleGraphs.accessors_of("memories:workspace:#{workspace.id}")

      user_ids = Enum.map(accessors, & &1.user_id) |> Enum.sort()
      assert user_a.id in user_ids
      assert user_b.id in user_ids
      assert Enum.all?(accessors, &(&1.type == :workspace))
      assert Enum.all?(accessors, &(&1.workspace_id == workspace.id))
    end

    test "brain graph maps to creator plus grantees" do
      user_a = generate(user())
      user_b = generate(user())
      brain = generate(brain(user_id: user_a.id))

      {:ok, _} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :brain,
            resource_id: brain.id,
            grantee_type: :user,
            grantee_id: user_b.id,
            role: :viewer
          },
          actor: user_a
        )

      accessors = Magus.SuperBrain.AccessibleGraphs.accessors_of("brain:#{brain.id}")
      user_ids = Enum.map(accessors, & &1.user_id) |> Enum.sort()
      assert user_a.id in user_ids
      assert user_b.id in user_ids
    end

    test "unknown graph prefix returns empty list" do
      assert Magus.SuperBrain.AccessibleGraphs.accessors_of("unknown:foo:bar") == []
    end
  end
end
