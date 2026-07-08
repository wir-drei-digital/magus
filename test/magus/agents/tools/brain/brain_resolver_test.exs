defmodule Magus.Agents.Tools.Brain.BrainResolverTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Brain.BrainResolver
  alias Magus.Brain
  alias Magus.Workspaces

  defp create_test_data do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Page One"}, actor: user)

    %{user: user, brain: brain, page: page}
  end

  defp create_workspace_test_data do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{
          name: "Resolver WS",
          slug: "resolver-ws-#{System.unique_integer([:positive])}"
        },
        actor: user
      )

    {:ok, personal_brain} = Brain.create_brain(%{title: "Personal Brain"}, actor: user)

    {:ok, workspace_brain} =
      Brain.create_brain(
        %{title: "Workspace Brain", workspace_id: workspace.id},
        actor: user
      )

    %{
      user: user,
      workspace: workspace,
      personal_brain: personal_brain,
      workspace_brain: workspace_brain
    }
  end

  describe "resolve_brain_id/2" do
    test "returns explicit brain_id from params" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{"brain_id" => brain.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "returns brain_id from params with atom key" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{brain_id: brain.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "falls back to brain_id from context" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user, brain_id: brain.id}
      params = %{}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "falls back to brain_id from context with string key" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user} |> Map.put("brain_id", brain.id)
      params = %{}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "auto-discovers user's default brain when no param or context" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "auto-discovers most recently updated brain" do
      user = generate(user())
      {:ok, _older} = Brain.create_brain(%{title: "Older Brain"}, actor: user)
      {:ok, newer} = Brain.create_brain(%{title: "Newer Brain"}, actor: user)

      context = %{user_id: user.id, user: user}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, %{})
      assert brain_id == newer.id
    end

    test "returns error when user has no brains" do
      user = generate(user())
      context = %{user_id: user.id, user: user}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, %{})
      assert message =~ "No brain found"
    end

    test "returns error when context has no user" do
      assert {:error, message} = BrainResolver.resolve_brain_id(%{}, %{})
      assert message =~ "Missing"
    end

    test "auto-discovers workspace brain when context has workspace_id" do
      %{user: user, workspace: workspace, workspace_brain: workspace_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, %{})
      assert brain_id == workspace_brain.id
    end

    test "ignores personal brain when context has workspace_id" do
      %{user: user, workspace: workspace, personal_brain: personal_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, %{})
      refute brain_id == personal_brain.id
    end

    test "falls back to personal brain when context has no workspace_id" do
      %{user: user, personal_brain: personal_brain} = create_workspace_test_data()

      context = %{user_id: user.id, user: user}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, %{})
      assert brain_id == personal_brain.id
    end

    test "explicit personal brain_id is allowed from a workspace context" do
      %{user: user, workspace: workspace, personal_brain: personal_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}
      params = %{"brain_id" => personal_brain.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == personal_brain.id
    end

    test "rejects an explicit brain_id from a different workspace" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, ws_a} =
        Workspaces.create_workspace(
          %{name: "WS A", slug: "ws-a-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, ws_b} =
        Workspaces.create_workspace(
          %{name: "WS B", slug: "ws-b-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, brain_b} =
        Brain.create_brain(%{title: "Brain B", workspace_id: ws_b.id}, actor: user)

      # Conversation is scoped to workspace A, agent passes a workspace-B brain id.
      context = %{user_id: user.id, user: user, workspace_id: ws_a.id}
      params = %{"brain_id" => brain_b.id}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, params)
      assert message =~ "different workspace"
    end

    test "rejects an explicit workspace brain_id from a personal context" do
      %{user: user, workspace_brain: workspace_brain} = create_workspace_test_data()

      # Personal conversation (no workspace), agent passes a workspace brain id.
      context = %{user_id: user.id, user: user}
      params = %{"brain_id" => workspace_brain.id}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, params)
      assert message =~ "different workspace"
    end

    test "allows an explicit workspace brain_id from the same workspace" do
      %{user: user, workspace: workspace, workspace_brain: workspace_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}
      params = %{"brain_id" => workspace_brain.id}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == workspace_brain.id
    end

    # The open-pane brain (`context[:brain_id]`) is workspace-scoped exactly like
    # an explicit param. It used to be trusted blindly, so a cross-workspace pane
    # brain was usable via context but rejected via explicit id — the very
    # inconsistency that confused the agent. Strict separation on every path.
    test "rejects a context brain_id from a different workspace" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, ws_a} =
        Workspaces.create_workspace(
          %{name: "Ctx WS A", slug: "ctx-ws-a-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, ws_b} =
        Workspaces.create_workspace(
          %{name: "Ctx WS B", slug: "ctx-ws-b-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, brain_b} =
        Brain.create_brain(%{title: "Ctx Brain B", workspace_id: ws_b.id}, actor: user)

      # Conversation in workspace A, pane holds a workspace-B brain.
      context = %{user_id: user.id, user: user, workspace_id: ws_a.id, brain_id: brain_b.id}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, %{})
      assert message =~ "different workspace"
    end

    test "rejects a context workspace brain_id from a personal context" do
      %{user: user, workspace_brain: workspace_brain} = create_workspace_test_data()

      # Personal conversation (no workspace_id), pane holds a workspace brain —
      # the reported scenario. Must be rejected, not silently used.
      context = %{user_id: user.id, user: user, brain_id: workspace_brain.id}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, %{})
      assert message =~ "different workspace"
    end

    test "allows a context brain_id from the same workspace" do
      %{user: user, workspace: workspace, workspace_brain: workspace_brain} =
        create_workspace_test_data()

      context = %{
        user_id: user.id,
        user: user,
        workspace_id: workspace.id,
        brain_id: workspace_brain.id
      }

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, %{})
      assert brain_id == workspace_brain.id
    end

    test "resolves a brain by its slug" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "My Research Notes"}, actor: user)
      assert is_binary(brain.slug) and brain.slug != ""

      context = %{user_id: user.id, user: user}
      params = %{"brain_id" => brain.slug}

      assert {:ok, brain_id} = BrainResolver.resolve_brain_id(context, params)
      assert brain_id == brain.id
    end

    test "resolves a brain by its title, case-insensitively" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "My Research Notes"}, actor: user)
      context = %{user_id: user.id, user: user}

      assert {:ok, exact} =
               BrainResolver.resolve_brain_id(context, %{"brain_id" => "My Research Notes"})

      assert exact == brain.id

      assert {:ok, lower} =
               BrainResolver.resolve_brain_id(context, %{"brain_id" => "my research notes"})

      assert lower == brain.id
    end

    test "returns an actionable error when no brain matches the name" do
      user = generate(user())
      {:ok, _brain} = Brain.create_brain(%{title: "Real Brain"}, actor: user)

      context = %{user_id: user.id, user: user}
      params = %{"brain_id" => "Nonexistent Brain"}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, params)
      assert message =~ "No brain matches"
      # The available brains are listed so the agent can self-correct.
      assert message =~ "Real Brain"
    end

    test "duplicate titles yield an ambiguity error listing the ids" do
      user = generate(user())
      {:ok, b1} = Brain.create_brain(%{title: "Notes"}, actor: user)
      {:ok, b2} = Brain.create_brain(%{title: "Notes"}, actor: user)
      # Slugs are deduped per user, but the titles still collide.
      assert b1.slug != b2.slug

      context = %{user_id: user.id, user: user}
      params = %{"brain_id" => "Notes"}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, params)
      assert message =~ "Multiple brains"
      assert message =~ b1.id
      assert message =~ b2.id
    end

    test "a brain in another workspace cannot be reached by its title" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, ws_a} =
        Workspaces.create_workspace(
          %{name: "WS A", slug: "ws-a-name-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, ws_b} =
        Workspaces.create_workspace(
          %{name: "WS B", slug: "ws-b-name-#{System.unique_integer([:positive])}"},
          actor: user
        )

      {:ok, _brain_b} =
        Brain.create_brain(%{title: "Secret Plans", workspace_id: ws_b.id}, actor: user)

      # From a workspace-A conversation, the workspace-B brain's title must not resolve.
      context = %{user_id: user.id, user: user, workspace_id: ws_a.id}
      params = %{"brain_id" => "Secret Plans"}

      assert {:error, message} = BrainResolver.resolve_brain_id(context, params)
      assert message =~ "No brain matches"
    end
  end

  describe "resolve_brain_ids/2" do
    test "returns workspace brains when context has workspace_id" do
      %{user: user, workspace: workspace, workspace_brain: workspace_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}

      assert {:ok, pairs} = BrainResolver.resolve_brain_ids(context, user)
      assert Enum.any?(pairs, fn {id, _} -> id == workspace_brain.id end)
    end

    test "excludes workspace brains when context has no workspace_id" do
      %{user: user, workspace_brain: workspace_brain, personal_brain: personal_brain} =
        create_workspace_test_data()

      context = %{user_id: user.id, user: user}

      assert {:ok, pairs} = BrainResolver.resolve_brain_ids(context, user)
      refute Enum.any?(pairs, fn {id, _} -> id == workspace_brain.id end)
      assert Enum.any?(pairs, fn {id, _} -> id == personal_brain.id end)
    end
  end

  describe "resolve_page/3" do
    test "returns page by explicit page_id from params" do
      %{user: user, brain: brain, page: page} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{"page_id" => page.id}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.id == page.id
      assert resolved.title == "Page One"
    end

    test "returns page by page_title from params" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{"page_title" => "Page One"}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.title == "Page One"
    end

    test "returns error when page_title does not match any page" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{"page_title" => "Nonexistent Page"}

      assert {:error, message} = BrainResolver.resolve_page(context, params, brain.id)
      assert message =~ "No page found"
    end

    test "falls back to brain_page_id from context" do
      %{user: user, brain: brain, page: page} = create_test_data()
      context = %{user_id: user.id, user: user, brain_page_id: page.id}
      params = %{}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.id == page.id
    end

    test "falls back to brain_page_id from context with string key" do
      %{user: user, brain: brain, page: page} = create_test_data()
      context = %{user_id: user.id, user: user} |> Map.put("brain_page_id", page.id)
      params = %{}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.id == page.id
    end

    test "returns error when nothing resolves" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{}

      assert {:error, message} = BrainResolver.resolve_page(context, params, brain.id)
      assert message =~ "No page"
    end

    test "explicit page_id takes priority over page_title" do
      %{user: user, brain: brain, page: page} = create_test_data()
      {:ok, _page2} = Brain.create_page(brain.id, %{title: "Page Two"}, actor: user)

      context = %{user_id: user.id, user: user}
      params = %{"page_id" => page.id, "page_title" => "Page Two"}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.id == page.id
      assert resolved.title == "Page One"
    end

    test "page_title takes priority over context brain_page_id" do
      %{user: user, brain: brain, page: page} = create_test_data()
      {:ok, page2} = Brain.create_page(brain.id, %{title: "Page Two"}, actor: user)

      context = %{user_id: user.id, user: user, brain_page_id: page.id}
      params = %{"page_title" => "Page Two"}

      assert {:ok, resolved} = BrainResolver.resolve_page(context, params, brain.id)
      assert resolved.id == page2.id
      assert resolved.title == "Page Two"
    end
  end

  describe "resolve_page_id/3" do
    test "returns just the page ID" do
      %{user: user, brain: brain, page: page} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{"page_id" => page.id}

      assert {:ok, page_id} = BrainResolver.resolve_page_id(context, params, brain.id)
      assert page_id == page.id
    end

    test "propagates errors from resolve_page" do
      %{user: user, brain: brain} = create_test_data()
      context = %{user_id: user.id, user: user}
      params = %{}

      assert {:error, _} = BrainResolver.resolve_page_id(context, params, brain.id)
    end
  end
end
