defmodule MagusWeb.Workbench.Resources.AgentViewAutomationTest do
  @moduledoc """
  Tests for agent automation settings (heartbeat, triage, safety limits +
  manual "Run now" trigger), rendered inside the workbench AgentView as the
  :automation section.
  """
  use MagusWeb.LiveViewCase, async: false

  require Ash.Query

  alias Magus.Agents.AgentRun
  alias Magus.Usage
  alias MagusWeb.Workbench.Resources.AgentView

  defp setup_user_with_subscription do
    user = generate(user())

    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "test-plan-#{System.unique_integer([:positive])}",
          name: "Test Plan",
          storage_bytes: 1_000_000_000,
          max_upload_bytes: 100_000_000,
          is_active: true
        },
        authorize?: false
      )

    {:ok, _subscription} =
      Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    user
  end

  defp open_automation(user, agent) do
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
  end

  describe "Run now button" do
    test "renders a Run now button on the automation section" do
      user = setup_user_with_subscription()
      agent = custom_agent(user, %{})

      {:ok, _view, html} = open_automation(user, agent)

      assert html =~ "run-now"
      assert html =~ "Run now"
    end

    test "clicking Run now enqueues a manual_trigger AgentRun" do
      user = setup_user_with_subscription()
      agent = custom_agent(user, %{})

      {:ok, view, _html} = open_automation(user, agent)

      # The run-now button is inside the section LiveComponent; find it by data-section
      view
      |> Phoenix.LiveViewTest.element(
        "[data-section='automation'] #run-now-agent-section-automation"
      )
      |> Phoenix.LiveViewTest.render_click()

      runs =
        AgentRun
        |> Ash.Query.filter(target_agent_id == ^agent.id and source == :manual_trigger)
        |> Ash.read!(authorize?: false)

      assert length(runs) == 1
      [run] = runs
      assert run.kind == :delegate
      assert run.initiator_user_id == user.id
      assert run.objective == "Manual wake-up triggered from UI"
    end
  end
end
