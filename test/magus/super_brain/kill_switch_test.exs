defmodule Magus.SuperBrain.KillSwitchTest do
  @moduledoc """
  Verifies the `super_brain_enabled` master kill switch: when disabled, no
  Super Brain work runs — jobs cancel, enqueue sites skip, retrieval returns
  empty, and the per-message context block is not injected.

  test.exs enables Super Brain globally so the feature suite exercises real
  paths; these tests flip it off per-test and restore it.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Agents.Context.SuperBrainRagContext
  alias Magus.SuperBrain
  alias Magus.SuperBrain.Retrieval

  setup do
    prev = Application.get_env(:magus, :super_brain_enabled)
    Application.put_env(:magus, :super_brain_enabled, false)
    on_exit(fn -> Application.put_env(:magus, :super_brain_enabled, prev) end)
    :ok
  end

  test "enabled?/0 reflects the config flag" do
    refute SuperBrain.enabled?()
    Application.put_env(:magus, :super_brain_enabled, true)
    assert SuperBrain.enabled?()
  end

  describe "workers cancel when disabled" do
    test "ExtractBase-backed worker cancels without running" do
      assert {:cancel, :super_brain_disabled} =
               perform_job(SuperBrain.Workers.ExtractBrainPage, %{
                 "resource_id" => Ash.UUID.generate()
               })
    end

    test "build worker cancels without running" do
      assert {:cancel, :super_brain_disabled} =
               perform_job(SuperBrain.Workers.BuildSuperFull, %{
                 "accessor_type" => "user",
                 "user_id" => Ash.UUID.generate()
               })
    end

    test "scheduler worker cancels without enqueuing downstream jobs" do
      assert {:cancel, :super_brain_disabled} =
               perform_job(SuperBrain.Workers.BackfillScheduler, %{})

      refute_enqueued(worker: SuperBrain.Workers.ExtractBrainPage)
      refute_enqueued(worker: SuperBrain.Workers.ExtractMemory)
    end
  end

  describe "enqueue sites skip when disabled" do
    test "file chunk extraction is not enqueued" do
      assert :ok == Magus.Files.Chunk.enqueue_super_brain_extraction(Ash.UUID.generate())
      refute_enqueued(worker: SuperBrain.Workers.ExtractFileChunk)
    end

    test "draft extraction is not enqueued" do
      assert :ok == Magus.Drafts.Draft.enqueue_super_brain_extraction(Ash.UUID.generate())
      refute_enqueued(worker: SuperBrain.Workers.ExtractDraft)
    end
  end

  describe "query-time work is inert when disabled" do
    test "SuperBrainRagContext.build/1 returns nil" do
      user = generate(user())

      assert nil ==
               SuperBrainRagContext.build(%{
                 query: "what do I know about distributed systems",
                 user: user
               })
    end

    test "Retrieval.search/2 returns an empty super-graph result" do
      user = generate(user())

      assert {:ok, %{entities: []}} =
               Retrieval.search(user,
                 query: "anything",
                 query_embedding: [0.0, 0.0, 0.0],
                 workspace_context: nil,
                 limit: 8
               )
    end
  end
end
