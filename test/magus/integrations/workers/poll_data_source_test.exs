defmodule Magus.Integrations.Workers.PollDataSourceTest do
  use Magus.DataCase, async: true
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  alias Magus.Integrations.Workers.PollDataSource

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Poller"})

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :rss_source,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{"feed_url" => "https://example.com/feed.xml", "poll_interval_minutes" => 15}
        },
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, actor: user)

    %{user: user, integration: integration}
  end

  test "cancels if integration not found" do
    assert {:cancel, :integration_not_found} =
             PollDataSource.perform(%Oban.Job{
               args: %{"integration_id" => Ash.UUID.generate()}
             })
  end

  test "cancels if integration is not active", %{integration: integration} do
    {:ok, integration} =
      Magus.Integrations.deactivate_user_integration(integration, authorize?: false)

    assert {:cancel, :integration_inactive} =
             PollDataSource.perform(%Oban.Job{
               args: %{"integration_id" => integration.id}
             })
  end

  test "enqueue/1 inserts a job", %{integration: integration} do
    assert {:ok, %Oban.Job{}} = PollDataSource.enqueue(integration.id)
    assert_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})
  end
end
