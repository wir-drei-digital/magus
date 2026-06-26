defmodule Magus.SuperBrain.AuthorizationTest do
  @moduledoc """
  Property-based access boundary tests for `Magus.SuperBrain.AccessibleGraphs`.

  This is the safety net for the Super Brain retrieval pipeline: it must be
  impossible for an actor to receive a `brain:<id>` graph from
  `AccessibleGraphs.for_actor/2` unless the actor can read the underlying
  `Magus.Brain.BrainResource` via Ash policies.

  Brain graphs are the only graph names governed by `Magus.Workspaces.ResourceAccess`;
  personal `(memories|files|drafts):user:<id>` graphs always belong to the actor
  and workspace `(memories|files):workspace:<id>` graphs require active membership.

  The randomized property scenarios exercise creator ownership, workspace
  membership (including admin role), workspace grants, and direct user grants
  across multiple users, workspaces, and brains. Hand-crafted tests pin down
  the specific authorization shapes.
  """

  use Magus.ResourceCase, async: false
  use ExUnitProperties
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.Brain.BrainResource
  alias Magus.SuperBrain.AccessibleGraphs
  alias Magus.Workspaces

  setup :set_mox_from_context

  # ---------------------------------------------------------------------------
  # Hand-crafted edge cases
  # ---------------------------------------------------------------------------

  describe "brain graph visibility (hand-crafted cases)" do
    test "creator always sees their own brain graph (personal context)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: nil)

      assert "brain:#{brain.id}" in graphs
      assert can_read_brain?(user, brain)
    end

    test "creator always sees their own brain graph (workspace context)" do
      user = generate(user())
      ws = generate(workspace(actor: user))
      brain = generate(brain(user_id: user.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: ws.id)

      assert "brain:#{brain.id}" in graphs
      assert can_read_brain?(user, brain)
    end

    test "workspace member without grant cannot see another user's brain" do
      owner = generate(user())
      member = generate(user())
      ws = generate(workspace(actor: owner))
      workspace_member(user_id: member.id, workspace_id: ws.id, role: :member)

      brain = generate(brain(user_id: owner.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(member, workspace_context: ws.id)

      refute "brain:#{brain.id}" in graphs
      refute can_read_brain?(member, brain)
    end

    test "workspace member with :workspace :viewer grant can see the brain" do
      owner = generate(user())
      member = generate(user())
      ws = generate(workspace(actor: owner))
      workspace_member(user_id: member.id, workspace_id: ws.id, role: :member)

      brain = generate(brain(user_id: owner.id, workspace_id: ws.id))
      grant_workspace_viewer!(brain, ws, owner)

      graphs = AccessibleGraphs.for_actor(member, workspace_context: ws.id)

      assert "brain:#{brain.id}" in graphs
      assert can_read_brain?(member, brain)
    end

    test "workspace admin without explicit grant cannot read brains created by others" do
      # Read policy on brain does NOT include workspace admin bypass — admins
      # only get implicit owner role on update/destroy. This test pins that
      # invariant down so we notice if the policy macro changes.
      owner = generate(user())
      admin = generate(user())
      ws = generate(workspace(actor: owner))
      workspace_member(user_id: admin.id, workspace_id: ws.id, role: :admin)

      brain = generate(brain(user_id: owner.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(admin, workspace_context: ws.id)

      refute "brain:#{brain.id}" in graphs
      refute can_read_brain?(admin, brain)
    end

    test "direct user grant without membership: brain readable but graph hidden in workspace context" do
      # This is intentional: the brain lives in workspace W's graph store, so
      # AccessibleGraphs requires active membership in W before listing any
      # brains there. A direct grant gives Ash read access but does not put
      # the brain into the actor's accessible graphs.
      owner = generate(user())
      stranger = generate(user())
      ws = generate(workspace(actor: owner))
      # stranger is NOT a member of ws

      brain = generate(brain(user_id: owner.id, workspace_id: ws.id))
      grant_user_viewer!(brain, stranger, owner)

      assert can_read_brain?(stranger, brain)

      graphs_in_ws = AccessibleGraphs.for_actor(stranger, workspace_context: ws.id)
      refute "brain:#{brain.id}" in graphs_in_ws

      graphs_personal = AccessibleGraphs.for_actor(stranger, workspace_context: nil)
      refute "brain:#{brain.id}" in graphs_personal
    end

    test "wrong workspace_context hides a workspace brain from a member" do
      owner = generate(user())
      ws = generate(workspace(actor: owner))
      brain = generate(brain(user_id: owner.id, workspace_id: ws.id))

      graphs = AccessibleGraphs.for_actor(owner, workspace_context: nil)

      refute "brain:#{brain.id}" in graphs
    end

    test "personal graphs are always present regardless of workspace context" do
      user = generate(user())
      ws = generate(workspace(actor: user))

      for ctx <- [nil, ws.id] do
        graphs = AccessibleGraphs.for_actor(user, workspace_context: ctx)

        assert "memories:user:#{user.id}" in graphs
        assert "files:user:#{user.id}" in graphs
        assert "drafts:user:#{user.id}" in graphs
      end
    end

    test "workspace memory/file graphs require active membership" do
      owner = generate(user())
      ws = generate(workspace(actor: owner))
      outsider = generate(user())

      owner_graphs = AccessibleGraphs.for_actor(owner, workspace_context: ws.id)
      assert "memories:workspace:#{ws.id}" in owner_graphs
      assert "files:workspace:#{ws.id}" in owner_graphs

      outsider_graphs = AccessibleGraphs.for_actor(outsider, workspace_context: ws.id)
      refute "memories:workspace:#{ws.id}" in outsider_graphs
      refute "files:workspace:#{ws.id}" in outsider_graphs
    end
  end

  # ---------------------------------------------------------------------------
  # Property tests
  # ---------------------------------------------------------------------------

  describe "property: brain graph accessibility soundness" do
    # Safety property: if a brain graph is returned by AccessibleGraphs for an
    # actor in any workspace context, the actor MUST be able to read that brain
    # via Ash policies. This is the unbypassable invariant.
    property "brain graph in AccessibleGraphs implies brain is readable" do
      check all(spec <- scenario_spec(), max_runs: 25) do
        %{users: users, brains: brains} = setup_scenario(spec)

        for actor <- users, brain <- brains do
          contexts = if is_nil(brain.workspace_id), do: [nil], else: [nil, brain.workspace_id]

          for ctx <- contexts do
            graphs = AccessibleGraphs.for_actor(actor, workspace_context: ctx)
            in_graphs? = "brain:#{brain.id}" in graphs

            if in_graphs? do
              assert can_read_brain?(actor, brain), """
              SAFETY VIOLATION: actor can retrieve from brain graph they cannot read.
                actor=#{actor.id}
                brain=#{brain.id} workspace=#{inspect(brain.workspace_id)}
                workspace_context=#{inspect(ctx)}
                Brain was in AccessibleGraphs but Ash policy denies read.
              """
            end
          end
        end
      end
    end

    # Completeness property at the "natural" workspace context: when querying
    # with the brain's own workspace context, AccessibleGraphs returns the
    # brain iff (Ash policy allows read) AND (personal brain OR active
    # workspace membership). Direct user grants without membership are
    # intentionally excluded since the workspace graph store is not opened
    # for non-members.
    property "brain graph appears iff readable and (personal or active member)" do
      check all(spec <- scenario_spec(), max_runs: 25) do
        %{users: users, brains: brains} = setup_scenario(spec)

        for actor <- users, brain <- brains do
          ctx = brain.workspace_id
          readable? = can_read_brain?(actor, brain)
          in_scope? = is_nil(brain.workspace_id) or active_member?(actor, brain.workspace_id)
          expected_in_graphs? = readable? and in_scope?

          graphs = AccessibleGraphs.for_actor(actor, workspace_context: ctx)
          actual_in_graphs? = "brain:#{brain.id}" in graphs

          assert expected_in_graphs? == actual_in_graphs?, """
          MISMATCH:
            actor=#{actor.id}
            brain=#{brain.id} workspace=#{inspect(brain.workspace_id)}
            workspace_context=#{inspect(ctx)}
            readable_via_ash=#{readable?}
            in_workspace_scope=#{in_scope?}
            expected=#{expected_in_graphs?} actual=#{actual_in_graphs?}
          """
        end
      end
    end
  end

  describe "property: workspace and personal graph rules" do
    property "personal graphs are always present for any actor" do
      check all(spec <- scenario_spec(), max_runs: 25) do
        %{users: users, workspaces: workspaces} = setup_scenario(spec)

        for actor <- users do
          contexts = [nil | Enum.map(workspaces, & &1.id)]

          for ctx <- contexts do
            graphs = AccessibleGraphs.for_actor(actor, workspace_context: ctx)
            assert "memories:user:#{actor.id}" in graphs
            assert "files:user:#{actor.id}" in graphs
            assert "drafts:user:#{actor.id}" in graphs
          end
        end
      end
    end

    property "workspace graphs appear iff actor is an active member" do
      check all(spec <- scenario_spec(), max_runs: 25) do
        %{users: users, workspaces: workspaces} = setup_scenario(spec)

        for actor <- users, ws <- workspaces do
          graphs = AccessibleGraphs.for_actor(actor, workspace_context: ws.id)
          member? = active_member?(actor, ws.id)

          has_memories? = "memories:workspace:#{ws.id}" in graphs
          has_files? = "files:workspace:#{ws.id}" in graphs

          assert member? == has_memories?, """
          workspace memory graph leak:
            actor=#{actor.id} ws=#{ws.id} member?=#{member?} has=#{has_memories?}
          """

          assert member? == has_files?, """
          workspace files graph leak:
            actor=#{actor.id} ws=#{ws.id} member?=#{member?} has=#{has_files?}
          """
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario generation
  # ---------------------------------------------------------------------------

  # Spec is purely data (atoms, integers, references by index) so StreamData
  # can shrink it without creating DB rows. setup_scenario/1 materializes it.
  defp scenario_spec do
    gen all(
          user_count <- integer(2..3),
          ws_count <- integer(1..2),
          brain_specs <-
            list_of(brain_spec(user_count, ws_count), min_length: 2, max_length: 5),
          membership_specs <-
            list_of(membership_spec(user_count, ws_count), max_length: 6),
          grant_specs <-
            list_of(grant_spec(user_count, ws_count), max_length: 6)
        ) do
      %{
        user_count: user_count,
        ws_count: ws_count,
        brains: brain_specs,
        memberships: membership_specs,
        grants: grant_specs
      }
    end
  end

  defp brain_spec(user_count, ws_count) do
    gen all(
          owner_ix <- integer(0..(user_count - 1)),
          # Either a personal brain or one in workspaces[0..ws_count-1].
          ws_ix <- integer(-1..(ws_count - 1))
        ) do
      %{owner_ix: owner_ix, ws_ix: ws_ix}
    end
  end

  defp membership_spec(user_count, ws_count) do
    gen all(
          user_ix <- integer(0..(user_count - 1)),
          ws_ix <- integer(0..(ws_count - 1)),
          role <- member_of([:member, :admin])
        ) do
      %{user_ix: user_ix, ws_ix: ws_ix, role: role}
    end
  end

  defp grant_spec(user_count, ws_count) do
    gen all(
          brain_ix <- integer(0..9),
          shape <- member_of([:user, :workspace]),
          target_ix <- integer(0..(max(user_count, ws_count) - 1)),
          role <- member_of([:viewer, :editor, :owner])
        ) do
      %{brain_ix: brain_ix, shape: shape, target_ix: target_ix, role: role}
    end
  end

  defp setup_scenario(spec) do
    users = for _ <- 1..spec.user_count, do: generate(user())
    workspaces = for [u | _] <- [users], _ <- 1..spec.ws_count, do: generate(workspace(actor: u))

    # Workspace creators are automatically admins of "their" workspace via
    # CreateOwnerMember. Track existing memberships and add additional ones
    # from the spec (deduping by {user, ws}).
    initial_seen = MapSet.new(Enum.map(workspaces, &{Enum.at(users, 0).id, &1.id}))

    seen_after_spec =
      Enum.reduce(spec.memberships, initial_seen, fn m, seen ->
        user = Enum.at(users, m.user_ix)
        ws = Enum.at(workspaces, m.ws_ix)
        key = {user.id, ws.id}

        if MapSet.member?(seen, key) do
          seen
        else
          workspace_member(user_id: user.id, workspace_id: ws.id, role: m.role)
          MapSet.put(seen, key)
        end
      end)

    # Brain creation requires the actor to be an active workspace member. Add
    # missing memberships before creating brains so the property scenarios can
    # exercise diverse owner/workspace combinations without setup failures.
    seen_with_brain_owners =
      Enum.reduce(spec.brains, seen_after_spec, fn b, seen ->
        if b.ws_ix < 0 do
          seen
        else
          user = Enum.at(users, b.owner_ix)
          ws = Enum.at(workspaces, b.ws_ix)
          key = {user.id, ws.id}

          if MapSet.member?(seen, key) do
            seen
          else
            workspace_member(user_id: user.id, workspace_id: ws.id, role: :member)
            MapSet.put(seen, key)
          end
        end
      end)

    _ = seen_with_brain_owners

    brains =
      Enum.map(spec.brains, fn b ->
        owner = Enum.at(users, b.owner_ix)
        ws = if b.ws_ix >= 0, do: Enum.at(workspaces, b.ws_ix), else: nil
        ws_id = ws && ws.id
        generate(brain(user_id: owner.id, workspace_id: ws_id))
      end)

    # Apply grants. Skip those that reference non-existent brain indices or
    # target indices outside the user/workspace pool.
    Enum.each(spec.grants, fn g ->
      with brain when not is_nil(brain) <- Enum.at(brains, g.brain_ix) do
        owner = Enum.find(users, &(&1.id == brain.user_id))
        apply_grant_safely(brain, g, users, workspaces, owner)
      end
    end)

    %{users: users, workspaces: workspaces, brains: brains}
  end

  defp apply_grant_safely(brain, %{shape: :user} = g, users, _workspaces, owner) do
    case Enum.at(users, g.target_ix) do
      nil ->
        :ok

      target ->
        # Don't grant to the creator (would be a duplicate / no-op shape).
        if target.id != owner.id do
          _ = grant_user!(brain, target, g.role, owner)
        end
    end
  end

  defp apply_grant_safely(brain, %{shape: :workspace} = g, _users, workspaces, owner) do
    case Enum.at(workspaces, g.target_ix) do
      nil ->
        :ok

      ws ->
        # Workspace grants only make sense when the brain lives in some
        # workspace (the AccessibleGraphs only consults them in that context).
        # Granting to an unrelated workspace is still valid data — keep it
        # to exercise the policy's cross-workspace behavior.
        _ = grant_workspace!(brain, ws, g.role, owner)
    end
  end

  defp grant_user!(brain, target, role, actor) do
    Workspaces.grant_access(
      %{
        resource_type: :brain,
        resource_id: brain.id,
        grantee_type: :user,
        grantee_id: target.id,
        role: role
      },
      actor: actor
    )
  end

  defp grant_workspace!(brain, ws, role, actor) do
    Workspaces.grant_access(
      %{
        resource_type: :brain,
        resource_id: brain.id,
        grantee_type: :workspace,
        grantee_id: ws.id,
        role: role
      },
      actor: actor
    )
  end

  defp grant_user_viewer!(brain, target, actor) do
    {:ok, _} = grant_user!(brain, target, :viewer, actor)
    :ok
  end

  defp grant_workspace_viewer!(brain, ws, actor) do
    {:ok, _} = grant_workspace!(brain, ws, :viewer, actor)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Oracles (ground truth via real Ash policy enforcement)
  # ---------------------------------------------------------------------------

  defp can_read_brain?(actor, brain) do
    case Ash.get(BrainResource, brain.id, actor: actor) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp active_member?(actor, ws_id) do
    require Ash.Query

    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(user_id == ^actor.id and workspace_id == ^ws_id and is_active == true)
    |> Ash.exists?(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Iter2 resource-type boundary tests (memory, file_chunk, draft)
  # ---------------------------------------------------------------------------
  #
  # Iter1's `AccessibleGraphs.for_actor/2` already routes all four resource
  # types' graphs uniformly, and the property tests above cover the workspace
  # boundary for memories/files via randomized fuzzing. These hand-crafted
  # tests pin the invariants explicitly per resource type so a regression in
  # any single graph kind shows up as a focused failure.

  describe "memory access boundary" do
    test "user with no membership in workspace cannot see workspace memories graph" do
      user_a = generate(user())
      user_b = generate(user())
      ws = generate(workspace(actor: user_b))

      graphs = AccessibleGraphs.for_actor(user_a, workspace_context: ws.id)

      refute "memories:workspace:#{ws.id}" in graphs
    end

    test "active workspace member sees the workspace memories graph" do
      user = generate(user())
      ws = generate(workspace(actor: user))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: ws.id)

      assert "memories:workspace:#{ws.id}" in graphs
    end
  end

  describe "file_chunk access boundary" do
    test "files:workspace graph follows the same membership rule as memories" do
      user_a = generate(user())
      user_b = generate(user())
      ws = generate(workspace(actor: user_b))

      graphs = AccessibleGraphs.for_actor(user_a, workspace_context: ws.id)

      refute "files:workspace:#{ws.id}" in graphs
    end

    test "active workspace member sees the workspace files graph" do
      user = generate(user())
      ws = generate(workspace(actor: user))

      graphs = AccessibleGraphs.for_actor(user, workspace_context: ws.id)

      assert "files:workspace:#{ws.id}" in graphs
    end
  end

  describe "draft access boundary" do
    test "drafts:user:<id> is always returned for the actor themselves and never others" do
      user_a = generate(user())
      user_b = generate(user())

      graphs_a = AccessibleGraphs.for_actor(user_a, workspace_context: nil)
      graphs_b = AccessibleGraphs.for_actor(user_b, workspace_context: nil)

      assert "drafts:user:#{user_a.id}" in graphs_a
      refute "drafts:user:#{user_b.id}" in graphs_a
      assert "drafts:user:#{user_b.id}" in graphs_b
      refute "drafts:user:#{user_a.id}" in graphs_b
    end
  end

  # ---------------------------------------------------------------------------
  # Layer 2 super graph build invariant (iter3)
  # ---------------------------------------------------------------------------
  #
  # Iter1+iter2's property tests above cover the Layer 1 read-set boundary
  # (`AccessibleGraphs.for_actor/2`). Iter3 adds the Layer 2 boundary: the
  # super graph builder reads `AccessibleGraphs.for_actor/2` itself to
  # compute its read-set, so a leak at this layer would be a regression of
  # the boundary contract rather than a duplicate check.
  #
  # This property is tagged `:slow` because every scenario runs full
  # FalkorDB extractions plus a super graph build per user. CI environments
  # without FalkorDB skip via `:integration`.

  describe "super graph build auth invariant" do
    @describetag :slow
    @describetag :integration

    property "BuildSuperFull produces only entities derived from graphs the actor can read" do
      check all(
              user_count <- integer(2..3),
              ws_count <- integer(1..2),
              brain_count <- integer(1..3),
              max_runs: 10
            ) do
        # Deterministic unit embeddings keep the extraction + clustering
        # behavior predictable across runs. We use a constant non-zero
        # vector so cosine similarity is well-defined.
        Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
          {:ok, Enum.map(texts, fn _ -> List.duplicate(1.0, 1536) end)}
        end)

        Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
          {:ok, List.duplicate(1.0, 1536)}
        end)

        users = for _ <- 1..user_count, do: generate(user())
        owner = hd(users)
        workspaces = for _ <- 1..ws_count, do: generate(workspace(actor: owner))

        # Random membership: each non-owner user joins each workspace with
        # probability 50%. The workspace creator is already an admin.
        for u <- users, ws <- workspaces, u.id != owner.id, :rand.uniform() < 0.5 do
          workspace_member(user_id: u.id, workspace_id: ws.id, role: :member)
        end

        # Random brains. Each brain lives either in a random workspace
        # (creator must be an active member) or is personal. Pick the
        # owner from workspace members so brain creation policies pass.
        brains =
          for _ <- 1..brain_count do
            ws = if :rand.uniform() < 0.7, do: Enum.random(workspaces), else: nil

            case ws do
              nil ->
                generate(brain(user_id: Enum.random(users).id))

              ws ->
                eligible = eligible_brain_owners(users, owner, ws)
                brain_owner = Enum.random(eligible)
                generate(brain(user_id: brain_owner.id, workspace_id: ws.id))
            end
          end

        # Drive an extraction into each brain.
        Enum.each(brains, fn brain ->
          on_exit(fn -> Magus.Graph.drop("brain:#{brain.id}") end)

          page =
            brain_page(brain_id: brain.id, user_id: brain.user_id, content: "Subject matter.")

          expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
            {:ok,
             %{
               content:
                 ~s({"entities":[{"name":"E","type":"concept","subtype":null,"confidence":0.9}],"edges":[]}),
               usage: %Magus.SuperBrain.Usage{
                 model_name: "t",
                 total_tokens: 1,
                 input_cost: Decimal.new("0"),
                 output_cost: Decimal.new("0"),
                 total_cost: Decimal.new("0")
               }
             }}
          end)

          :ok =
            perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})
        end)

        # Drain any BuildSuperIncremental fan-out enqueued by extraction.
        Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

        # For each user, build their personal super graph and verify that
        # every entity in the super graph traces back to a graph the user
        # could read at build time.
        Enum.each(users, fn user ->
          on_exit(fn -> Magus.Graph.drop("super:user:#{user.id}") end)

          on_exit(fn ->
            Magus.Graph.drop("memories:user:#{user.id}")
            Magus.Graph.drop("files:user:#{user.id}")
            Magus.Graph.drop("drafts:user:#{user.id}")
          end)

          :ok =
            perform_job(Magus.SuperBrain.Workers.BuildSuperFull, %{
              "accessor_type" => "user",
              "user_id" => user.id,
              "workspace_id" => nil
            })

          readable_graphs =
            user
            |> AccessibleGraphs.for_actor(workspace_context: nil)
            |> Enum.reject(&String.starts_with?(&1, "super:"))

          {:ok, result} =
            Magus.Graph.query(
              "super:user:#{user.id}",
              "MATCH (c:CanonicalEntity)-[:APPEARS_IN]->(s:SourcePointer) RETURN s.graph_name"
            )

          appearing_graphs =
            result.rows
            |> List.flatten()
            |> Enum.uniq()

          Enum.each(appearing_graphs, fn g ->
            assert g in readable_graphs, """
            SUPER GRAPH AUTH LEAK:
              user=#{user.id}
              super_graph=super:user:#{user.id}
              entity sourced from graph=#{inspect(g)}
              not in readable set=#{inspect(readable_graphs)}
            """
          end)
        end)
      end
    end

    # Returns the set of users who can legally create a brain in `ws`:
    # the workspace owner plus any user we explicitly added as a member.
    # The creator is implicitly an admin via `CreateOwnerMember`, so
    # `owner` is always eligible. Brains created without an active
    # membership would fail the create policy, so this filter keeps the
    # scenario internally consistent.
    defp eligible_brain_owners(users, owner, ws) do
      require Ash.Query

      member_ids =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Query.filter(workspace_id == ^ws.id and is_active == true)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.user_id)
        |> MapSet.new()
        |> MapSet.put(owner.id)

      Enum.filter(users, &MapSet.member?(member_ids, &1.id))
    end
  end
end
