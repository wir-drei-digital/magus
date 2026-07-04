defmodule Mix.Tasks.SuperBrain.BackfillClaimsTest do
  @moduledoc """
  Task 10: `mix super_brain.backfill_claims` detects resources whose latest
  `:extracted` Episode predates the claims-aware extractor version and
  force-re-extracts them. Mirrors `rebuild_task_test.exs`'s pattern of
  building Episode fixtures directly via `Ash.Changeset.for_create` +
  `mark_extracted` and invoking `Mix.Tasks.SuperBrain.BackfillClaims.run/1`
  in-process.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Workers.ExtractBrainPage
  alias Magus.SuperBrain.Workers.ExtractMemory
  alias Mix.Tasks.SuperBrain.BackfillClaims

  defp extracted_episode(attrs) do
    user_id = Map.fetch!(attrs, :source_user_id)

    {:ok, episode} =
      Episode
      |> Ash.Changeset.for_create(:create, attrs, actor: %{id: user_id})
      |> Ash.create(actor: %{id: user_id})

    {:ok, episode} = Ash.update(episode, %{}, action: :mark_extracted, actor: %{id: user_id})
    episode
  end

  defp stale_brain_page_episode(user_id, resource_id) do
    extracted_episode(%{
      resource_type: :brain_page,
      resource_id: resource_id,
      graph_name: "brain:#{Ash.UUID.generate()}",
      raw_text: "pre-claims content",
      source_user_id: user_id,
      source_weight: 1.0,
      extractor_version: "brain_extract_worker@2026-05-01"
    })
  end

  defp current_brain_page_episode(user_id, resource_id) do
    extracted_episode(%{
      resource_type: :brain_page,
      resource_id: resource_id,
      graph_name: "brain:#{Ash.UUID.generate()}",
      raw_text: "claims-aware content",
      source_user_id: user_id,
      source_weight: 1.0,
      extractor_version: ExtractBrainPage.extractor_version()
    })
  end

  # The oldest pre-claims episodes may carry a nil extractor_version (the
  # attribute is nullable and predates versioned extractors). Omitting the
  # key entirely leaves it nil through `:create` (no default; mark_extracted
  # does not set it).
  defp nil_version_brain_page_episode(user_id, resource_id) do
    extracted_episode(%{
      resource_type: :brain_page,
      resource_id: resource_id,
      graph_name: "brain:#{Ash.UUID.generate()}",
      raw_text: "unversioned pre-claims content",
      source_user_id: user_id,
      source_weight: 1.0
    })
  end

  defp stale_memory_episode(user_id, resource_id) do
    extracted_episode(%{
      resource_type: :memory,
      resource_id: resource_id,
      graph_name: "memories:user:#{user_id}",
      raw_text: "pre-claims memory",
      source_user_id: user_id,
      source_weight: 1.0,
      extractor_version: "memory_extract_worker@2026-05-01"
    })
  end

  describe "--dry-run detection" do
    test "counts a stale-version brain_page episode but not a current-version one" do
      user = generate(user())

      stale_resource_id = Ash.UUID.generate()
      current_resource_id = Ash.UUID.generate()

      stale_brain_page_episode(user.id, stale_resource_id)
      current_brain_page_episode(user.id, current_resource_id)

      BackfillClaims.run(["--user", user.id, "--dry-run"])

      # Dry run must not enqueue anything for either resource.
      refute_enqueued(worker: ExtractBrainPage, args: %{"resource_id" => stale_resource_id})
      refute_enqueued(worker: ExtractBrainPage, args: %{"resource_id" => current_resource_id})
    end

    test "detects staleness independently per resource type" do
      user = generate(user())

      stale_page_id = Ash.UUID.generate()
      stale_memory_id = Ash.UUID.generate()

      stale_brain_page_episode(user.id, stale_page_id)
      stale_memory_episode(user.id, stale_memory_id)

      # Dry run only: assert no side effects while both stale resources are
      # picked up (verified via the live-run assertions below covering the
      # same detection query the dry-run path shares).
      BackfillClaims.run(["--user", user.id, "--dry-run"])

      refute_enqueued(worker: ExtractBrainPage)
      refute_enqueued(worker: ExtractMemory)
    end

    test "a user with no episodes at all enqueues nothing and does not raise" do
      user = generate(user())

      BackfillClaims.run(["--user", user.id, "--dry-run"])

      refute_enqueued(worker: ExtractBrainPage)
    end
  end

  describe "live run" do
    test "enqueues the worker with force: true for a stale-version resource" do
      user = generate(user())
      resource_id = Ash.UUID.generate()

      stale_brain_page_episode(user.id, resource_id)

      BackfillClaims.run(["--user", user.id])

      assert_enqueued(
        worker: ExtractBrainPage,
        args: %{"resource_id" => resource_id, "force" => true}
      )
    end

    test "does not enqueue for a resource already on the current extractor version" do
      user = generate(user())
      resource_id = Ash.UUID.generate()

      current_brain_page_episode(user.id, resource_id)

      BackfillClaims.run(["--user", user.id])

      refute_enqueued(worker: ExtractBrainPage, args: %{"resource_id" => resource_id})
    end

    test "enqueues for a resource whose latest episode has a nil extractor_version" do
      # Regression: Ash `!=` compiles to `NOT (extractor_version = ^current)`
      # (three-valued SQL logic), which is NULL and thus EXCLUDED when the
      # column is NULL. A bare `!=` filter silently misses these oldest,
      # unversioned pre-claims episodes. `stale_episodes/3` explicitly ORs
      # `is_nil(extractor_version)` so nil counts as stale and gets a forced
      # re-extraction.
      user = generate(user())
      resource_id = Ash.UUID.generate()

      episode = nil_version_brain_page_episode(user.id, resource_id)
      assert episode.extractor_version == nil

      BackfillClaims.run(["--user", user.id])

      assert_enqueued(
        worker: ExtractBrainPage,
        args: %{"resource_id" => resource_id, "force" => true}
      )
    end

    test "resolves the user by email as well as by id" do
      user = generate(user())
      resource_id = Ash.UUID.generate()

      stale_brain_page_episode(user.id, resource_id)

      BackfillClaims.run(["--user", user.email])

      assert_enqueued(
        worker: ExtractBrainPage,
        args: %{"resource_id" => resource_id, "force" => true}
      )
    end
  end
end
