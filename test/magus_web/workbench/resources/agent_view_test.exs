defmodule MagusWeb.Workbench.Resources.AgentViewTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.AgentView

  # ---------------------------------------------------------------------------
  # Inspect mode tests (live_isolated with session)
  # ---------------------------------------------------------------------------

  test "renders the agent's name and description" do
    user = generate(user())

    {:ok, agent} =
      Magus.Agents.create_custom_agent(
        %{name: "Research Bot", description: "Does research"},
        actor: user
      )

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        AgentView,
        session: %{
          "agent_id" => agent.id,
          "user_id" => user.id
        }
      )

    assert html =~ "Research Bot"
    assert html =~ "Does research"
    assert html =~ ~s(data-agent-view)
  end

  test "renders not-found state when agent is missing" do
    user = generate(user())

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        AgentView,
        session: %{
          "agent_id" => Ecto.UUID.generate(),
          "user_id" => user.id
        }
      )

    assert html =~ "not found"
  end

  # ---------------------------------------------------------------------------
  # Edit mode tests (session-based: simulate what TabContainer passes)
  # ---------------------------------------------------------------------------

  describe "agent edit mode via session" do
    setup do
      user = generate(user())

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Edit me", instructions: "do things"},
          actor: user
        )

      %{user: user, agent: agent}
    end

    test "defaults to inspect mode (no edit nav)", %{user: user, agent: agent} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{"agent_id" => agent.id, "user_id" => user.id}
        )

      refute html =~ ~s(data-edit-section-nav)
    end

    test "renders edit mode when session has edit=true", %{user: user, agent: agent} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true"
          }
        )

      assert html =~ ~s(data-edit-section-nav)
      assert html =~ ~s(data-section="general")
    end

    test "renders tools section when session has section=tools", %{user: user, agent: agent} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "tools"
          }
        )

      assert html =~ ~s(data-section="tools")
    end

    test "renders privacy section when session has section=privacy", %{user: user, agent: agent} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "privacy"
          }
        )

      assert html =~ ~s(data-section="privacy")
    end

    test "renders automation section when session has section=automation", %{
      user: user,
      agent: agent
    } do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "automation"
          }
        )

      assert html =~ ~s(data-section="automation")
    end

    test "falls back to general for unknown section", %{user: user, agent: agent} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "bogus"
          }
        )

      assert html =~ ~s(data-section="general")
    end

    test "enter_edit event switches to edit mode", %{user: user, agent: agent} do
      {:ok, lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{"agent_id" => agent.id, "user_id" => user.id}
        )

      refute html =~ ~s(data-edit-section-nav)

      html = Phoenix.LiveViewTest.render_click(lv, "enter_edit")
      assert html =~ ~s(data-edit-section-nav)
    end

    test "set_section event changes the active section", %{user: user, agent: agent} do
      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "general"
          }
        )

      html = Phoenix.LiveViewTest.render_click(lv, "set_section", %{"section" => "privacy"})
      assert html =~ ~s(data-section="privacy")
    end

    # I1 regression: apply_action :agent must broadcast unconditionally so that
    # navigating from ?edit=true back to no-edit param exits edit mode in
    # already-mounted AgentViews.
    test "PubSub {:set_edit_state, false, :general} exits edit mode", %{user: user, agent: agent} do
      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true"
          }
        )

      assert Phoenix.LiveViewTest.render(lv) =~ ~s(data-edit-section-nav)

      # Simulate the parent WorkbenchLive broadcasting exit-edit (edit?=false)
      Phoenix.PubSub.broadcast(
        Magus.PubSub,
        "agent-view:#{agent.id}",
        {:set_edit_state, false, :general}
      )

      # Give the LiveView process time to handle the message
      Process.sleep(50)

      refute Phoenix.LiveViewTest.render(lv) =~ ~s(data-edit-section-nav)
    end
  end

  # ---------------------------------------------------------------------------
  # I6: ProfileImageGeneratorComponent message routing
  # ---------------------------------------------------------------------------

  # AgentView routes {ProfileImageGeneratorComponent, {:image_generated, path}}
  # messages to the General section via send_update. Testing this end-to-end
  # requires the General section component to be mounted (only happens in edit
  # mode with section=general) and for Magus.Files.Storage.get_url/1 to resolve
  # the path. In the test environment S3 is not configured, so we cannot make a
  # full assertion on the rendered URL. Instead this test verifies that:
  #   1. The message is accepted without crashing the LiveView process
  #   2. AgentView remains alive and functional after handling the message
  #
  # A deeper assertion (e.g. that the image URL appears in the rendered HTML)
  # would require mocking Magus.Files.Storage.get_url/1 or using a pre-signed
  # stub — tracked as a follow-up task.
  @tag :skip
  test "routes :image_generated messages to General section", %{} do
    # TODO: mock Magus.Files.Storage.get_url/1 and assert rendered image URL
    # appears in the General section component after the message is routed.
    flunk("not yet implemented — needs Storage mock")
  end

  describe "I6: image_generated message does not crash AgentView" do
    setup do
      user = generate(user())

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Image Bot", instructions: "generate images"},
          actor: user
        )

      %{user: user, agent: agent}
    end

    test "handle_info {:image_generated, path} is accepted without crash", %{
      user: user,
      agent: agent
    } do
      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          AgentView,
          session: %{
            "agent_id" => agent.id,
            "user_id" => user.id,
            "edit" => "true",
            "section" => "general"
          }
        )

      # Send the message that WorkbenchLive would forward after image generation.
      # The General section component (send_update target) may not process it
      # in the test environment if Storage.get_url/1 is not configured, but the
      # AgentView process itself must not crash.
      send(
        lv.pid,
        {MagusWeb.ProfileImageGeneratorComponent, {:image_generated, "agents/test/avatar.png"}}
      )

      Process.sleep(50)

      # AgentView is still alive and renders without error
      assert Phoenix.LiveViewTest.render(lv) =~ ~s(data-agent-view)
    end
  end

  # ---------------------------------------------------------------------------
  # Redirect tests (via full workbench route)
  # ---------------------------------------------------------------------------

  describe "legacy route redirects" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Redirect me", workspace_id: ws.id, instructions: "do things"},
          actor: user
        )

      %{conn: conn, agent: agent}
    end

    test "redirects /agents/:id/edit to ?edit=true", %{conn: conn, agent: agent} do
      assert {:error, {:redirect, %{to: dest}}} = live(conn, "/agents/#{agent.id}/edit")
      assert dest =~ "edit=true"
    end

    test "redirects /agents/:id/edit/tools to ?edit=true&section=tools", %{
      conn: conn,
      agent: agent
    } do
      assert {:error, {:redirect, %{to: dest}}} =
               live(conn, "/agents/#{agent.id}/edit/tools")

      assert dest =~ "section=tools"
    end

    test "/agents/new renders the new agent creation form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/agents/new")
      assert html =~ "New Agent"
      assert html =~ "Create Agent"
    end
  end
end
