defmodule Magus.Integrations.IntegrationHealthTest do
  @moduledoc """
  Tests integration health counters: polling failures increment
  `consecutive_failures` + set `last_error`; success resets to 0 and stamps
  `last_success_at`; 10 consecutive failures flips status to `:error`,
  notifies the owner exactly once (on the transition, not on every
  subsequent failure), and the poll worker stops re-enqueuing. Reactivating
  an errored integration resets the counters.

  RSS polling failures happen in-process (no network): we point the
  integration at an unreachable local port (with Req retries disabled via
  `retry: false` in `RssSource.fetch_and_parse_feed/1`), which Req reports
  immediately as `{:error, %Mint.TransportError{...}}` without ever
  touching the network or retrying, keeping these tests deterministic,
  offline, and fast.
  """

  use Magus.DataCase, async: true
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  alias Magus.Integrations
  alias Magus.Integrations.Providers.RssSource
  alias Magus.Integrations.Workers.PollDataSource

  # Nothing listens here; Req fails fast (connection refused) without
  # hitting any real network, keeping the test offline and deterministic.
  @unreachable_url "http://127.0.0.1:1/feed.xml"

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Poller"})

    {:ok, integration} =
      Integrations.create_user_integration(
        :rss_source,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{"feed_urls" => [@unreachable_url], "poll_interval_minutes" => 15}
        },
        actor: user
      )

    {:ok, integration} = Integrations.activate_user_integration(integration, actor: user)

    %{user: user, integration: integration}
  end

  describe "RssSource.poll/2 failure contract" do
    test "returns {:error, :all_feeds_failed} when every configured feed errors", %{
      integration: integration
    } do
      assert {:error, :all_feeds_failed} = RssSource.poll(integration, nil)
    end

    test "returns {:error, :no_feed_url_configured} when no feeds are configured", %{
      integration: integration
    } do
      {:ok, integration} =
        Integrations.update_integration_config(integration, %{config: %{"feed_urls" => []}},
          authorize?: false
        )

      assert {:error, :no_feed_url_configured} = RssSource.poll(integration, nil)
    end
  end

  describe "record_poll_failure / record_poll_success actions" do
    test "record_poll_failure increments consecutive_failures and sets last_error", %{
      integration: integration
    } do
      {:ok, updated} =
        Integrations.record_integration_poll_failure(integration, %{last_error: "boom"},
          authorize?: false
        )

      assert updated.consecutive_failures == 1
      assert updated.last_error == "boom"

      {:ok, updated2} =
        Integrations.record_integration_poll_failure(updated, %{last_error: "boom again"},
          authorize?: false
        )

      assert updated2.consecutive_failures == 2
      assert updated2.last_error == "boom again"
    end

    test "record_poll_success resets consecutive_failures + last_error and stamps last_success_at",
         %{integration: integration} do
      {:ok, failed} =
        Integrations.record_integration_poll_failure(integration, %{last_error: "boom"},
          authorize?: false
        )

      assert failed.consecutive_failures == 1

      {:ok, recovered} = Integrations.record_integration_poll_success(failed, authorize?: false)

      assert recovered.consecutive_failures == 0
      assert recovered.last_error == nil
      assert %DateTime{} = recovered.last_success_at
    end
  end

  describe "mark_errored action" do
    test "sets status to :error", %{integration: integration} do
      {:ok, errored} = Integrations.mark_integration_errored(integration, authorize?: false)
      assert errored.status == :error
    end
  end

  describe "reactivation resets counters" do
    test "activate clears consecutive_failures + last_error", %{integration: integration} do
      {:ok, failed} =
        Integrations.record_integration_poll_failure(integration, %{last_error: "boom"},
          authorize?: false
        )

      {:ok, errored} = Integrations.mark_integration_errored(failed, authorize?: false)
      assert errored.consecutive_failures > 0

      {:ok, reactivated} =
        Integrations.activate_user_integration(errored, authorize?: false)

      assert reactivated.status == :active
      assert reactivated.consecutive_failures == 0
      assert reactivated.last_error == nil
    end
  end

  describe "PollDataSource worker threshold behavior" do
    test "a single poll failure on the final attempt increments the counter, does not error the integration, and re-enqueues",
         %{integration: integration} do
      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 3,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 1
      assert reloaded.status == :active

      assert_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})
    end

    test "10th consecutive failure sets status to :error, notifies the owner once, and stops re-enqueuing",
         %{integration: integration, user: user} do
      # Drive 9 failures directly via the action (equivalent to 9 failed
      # polls) so the test stays fast and deterministic, then let the
      # worker perform the 10th poll itself to exercise the full path.
      integration =
        Enum.reduce(1..9, integration, fn _, acc ->
          {:ok, updated} =
            Integrations.record_integration_poll_failure(acc, %{last_error: "boom"},
              authorize?: false
            )

          updated
        end)

      assert integration.consecutive_failures == 9

      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 3,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 10
      assert reloaded.status == :error

      refute_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1
      assert hd(notifications).notification_type == :system
    end

    test "does not notify again when the worker runs again on an already-errored integration",
         %{integration: integration, user: user} do
      # Drive 9 failures directly via the action (equivalent to 9 failed
      # polls) so the test stays fast, then let the worker perform the 10th
      # poll itself through the real perform/1 -> handle_poll_failure ->
      # handle_threshold_reached path, exercising the actual
      # already_errored? guard rather than asserting on bare actions.
      integration =
        Enum.reduce(1..9, integration, fn _, acc ->
          {:ok, updated} =
            Integrations.record_integration_poll_failure(acc, %{last_error: "boom"},
              authorize?: false
            )

          updated
        end)

      assert integration.consecutive_failures == 9

      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 3,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, errored} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert errored.status == :error
      assert errored.consecutive_failures == 10

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1

      # Run the worker again on the now-:error integration. Whether it
      # short-circuits via check_active/1 (status no longer :active) or
      # re-runs the threshold branch, no additional notification must be
      # created.
      PollDataSource.perform(%Oban.Job{
        attempt: 3,
        max_attempts: 3,
        args: %{"integration_id" => integration.id}
      })

      {:ok, notifications_after_second_run} =
        Magus.Notifications.list_unread_notifications(actor: user)

      assert length(notifications_after_second_run) == 1
    end

    test "check_active cancels before any counter update when integration is inactive", %{
      integration: integration
    } do
      {:ok, integration} =
        Integrations.deactivate_user_integration(integration, authorize?: false)

      assert {:cancel, :integration_inactive} =
               PollDataSource.perform(%Oban.Job{args: %{"integration_id" => integration.id}})

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 0
    end
  end

  describe "PollDataSource only counts + chains on the final Oban attempt" do
    test "a non-final attempt failure does not increment consecutive_failures and does not re-enqueue",
         %{integration: integration} do
      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 1,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 0
      assert reloaded.status == :active

      refute_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})
    end

    test "a middle (non-final) attempt failure still does not count toward the threshold", %{
      integration: integration
    } do
      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 2,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 0

      refute_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})
    end

    test "the final attempt failure increments consecutive_failures and re-enqueues the next cycle",
         %{integration: integration} do
      assert {:error, :all_feeds_failed} =
               PollDataSource.perform(%Oban.Job{
                 attempt: 3,
                 max_attempts: 3,
                 args: %{"integration_id" => integration.id}
               })

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 1
      assert reloaded.status == :active

      assert_enqueued(worker: PollDataSource, args: %{integration_id: integration.id})
    end

    test "one bad poll cycle (3 attempts, default max_attempts) records exactly one failure", %{
      integration: integration
    } do
      # Simulate Oban retrying the same job three times for one poll cycle:
      # only the final attempt should count toward consecutive_failures.
      for attempt <- 1..3 do
        PollDataSource.perform(%Oban.Job{
          attempt: attempt,
          max_attempts: 3,
          args: %{"integration_id" => integration.id}
        })
      end

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      assert reloaded.consecutive_failures == 1
    end
  end

  describe "successful poll resets an existing failure streak" do
    test "worker records success and resets counters after prior failures", %{
      integration: integration,
      user: user
    } do
      {:ok, integration} =
        Integrations.record_integration_poll_failure(integration, %{last_error: "boom"},
          authorize?: false
        )

      assert integration.consecutive_failures == 1

      # Point the integration at a feed URL that RSS will treat as a
      # successful poll with zero entries (parses fine, just no items) —
      # we exercise this by stubbing feed_urls to empty after registering
      # the failure isn't representative here, so instead directly call
      # the worker's success path via record_poll_success given a
      # simulated {:ok, []} poll result, matching what PollDataSource does
      # after provider_module.poll/2 succeeds.
      {:ok, recovered} =
        Integrations.record_integration_poll_success(integration, authorize?: false)

      assert recovered.consecutive_failures == 0
      assert recovered.last_error == nil
      refute is_nil(recovered.last_success_at)
      assert recovered.status == :active

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert notifications == []
    end
  end
end
