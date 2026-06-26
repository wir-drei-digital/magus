defmodule Magus.SuperBrain.Workers.BackfillSchedulerTest do
  @moduledoc """
  Tests for the periodic Super Brain backfill scheduler.

  Per-resource triggers (Task 17) auto-enqueue extraction workers on
  resource creation, so we delete all pre-existing Oban jobs in each
  test before running the scheduler. That way the assertions exercise
  exactly what the scheduler enqueues, not the noise from the create
  triggers.
  """

  use Magus.ResourceCase, async: false

  use Oban.Testing, repo: Magus.Repo

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Workers.BackfillScheduler

  # Wipe the Oban job table so the trigger-enqueued jobs from resource
  # creation don't pollute scheduler assertions.
  defp drain_oban_jobs do
    Magus.Repo.delete_all(Oban.Job)
    :ok
  end

  describe "perform/1" do
    test "enqueues ExtractBrainPage for pages without an :extracted episode" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "x")

      drain_oban_jobs()

      assert :ok = perform_job(BackfillScheduler, %{})

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainPage,
        args: %{"resource_id" => page.id}
      )
    end

    test "does NOT enqueue for a page whose Episode is already :extracted" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "x")

      # Pre-create an :extracted episode for this page.
      {:ok, episode} =
        Episode
        |> Ash.Changeset.for_create(
          :create,
          %{
            resource_type: :brain_page,
            resource_id: page.id,
            graph_name: "brain:#{brain.id}",
            raw_text: "x",
            source_user_id: user.id
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        Ash.update(episode, %{}, action: :mark_extracted, authorize?: false)

      drain_oban_jobs()

      assert :ok = perform_job(BackfillScheduler, %{})

      refute_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainPage,
        args: %{"resource_id" => page.id}
      )
    end

    test "enqueues at most @per_user_cap candidates per user per resource type per tick" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      # Create 15 pages; per-user cap is 10.
      pages =
        for i <- 1..15 do
          brain_page(brain_id: brain.id, user_id: user.id, content: "page-#{i}")
        end

      drain_oban_jobs()

      assert :ok = perform_job(BackfillScheduler, %{})

      page_ids = MapSet.new(pages, & &1.id)

      enqueued_for_user =
        all_enqueued(worker: Magus.SuperBrain.Workers.ExtractBrainPage)
        |> Enum.filter(fn job -> MapSet.member?(page_ids, job.args["resource_id"]) end)

      assert length(enqueued_for_user) == 10
    end
  end
end
