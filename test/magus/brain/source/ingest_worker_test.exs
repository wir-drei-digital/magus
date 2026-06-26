defmodule Magus.Brain.Source.IngestWorkerTest do
  # async: false — this test puts Req.Test into shared-mode globally so the
  # worker (which runs in this pid via direct `perform/1`) sees the stubs.
  # Shared mode interferes with concurrent tests in other files that also
  # stub Req (e.g. WebFetch). Until we switch to per-process `Req.Test.allow/3`,
  # serialize this file.
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Source.{ChunkWorker, IngestWorker}

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)

    # Allow this test process to handle Req.Test stubs from any pid
    # (the worker `perform` runs in the test pid because we invoke it
    # synchronously). For Oban-executed runs we'd need `allow/3`, but
    # the tests below all call `perform/1` directly.
    Req.Test.set_req_test_to_shared(self())

    on_exit(fn -> Req.Test.set_req_test_from_context(%{}) end)

    %{user: user, brain: brain}
  end

  defp create_source(brain_id, attrs \\ %{}) do
    Ash.create!(
      Ash.Changeset.for_create(
        Brain.Source,
        :from_legacy_block,
        Map.merge(
          %{
            brain_id: brain_id,
            url: "https://example.com/article",
            ingest_status: :pending
          },
          attrs
        )
      ),
      authorize?: false
    )
  end

  defp run(source_id) do
    perform_job(IngestWorker, %{"source_id" => source_id})
  end

  describe "perform/1 success" do
    test "transitions :pending → :ingested with ingested_content set", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(conn, 200, """
        <html><head><title>Hello World</title></head>
        <body><p>Body text here.</p></body></html>
        """)
      end)

      source = create_source(brain.id)
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.ingest_status == :ingested
      assert reloaded.ingest_error == nil
      assert reloaded.ingested_at != nil
      assert reloaded.ingested_content =~ "Body text here."
    end

    test "enqueues ChunkWorker on success", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><body><p>Content.</p></body></html>")
      end)

      source = create_source(brain.id)
      assert :ok = run(source.id)

      assert_enqueued(worker: ChunkWorker, args: %{"source_id" => source.id})
    end

    test "fills title from fetched <title> when source.title is blank", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          "<html><head><title>Fetched Title</title></head><body>x</body></html>"
        )
      end)

      source = create_source(brain.id, %{title: nil})
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.title == "Fetched Title"
    end

    test "preserves user-supplied title even when HTML <title> differs", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          "<html><head><title>Page Title</title></head><body>x</body></html>"
        )
      end)

      source = create_source(brain.id, %{title: "My Title"})
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.title == "My Title"
    end
  end

  describe "perform/1 failure" do
    test "transitions :pending → :failed with ingest_error on HTTP error", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      source = create_source(brain.id)
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.ingest_status == :failed
      assert reloaded.ingest_error =~ "HTTP 500"
      assert reloaded.ingested_content == nil
    end

    test "transitions :pending → :failed on transport error", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      source = create_source(brain.id)
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.ingest_status == :failed
      assert reloaded.ingest_error =~ "econnrefused"
    end

    test "does not enqueue ChunkWorker on failure", %{brain: brain} do
      Req.Test.stub(IngestWorker, fn conn -> Plug.Conn.send_resp(conn, 500, "x") end)

      source = create_source(brain.id)
      assert :ok = run(source.id)

      refute_enqueued(worker: ChunkWorker, args: %{"source_id" => source.id})
    end

    test "retries from :failed state on next perform", %{brain: brain} do
      # First run fails.
      Req.Test.stub(IngestWorker, fn conn -> Plug.Conn.send_resp(conn, 500, "x") end)
      source = create_source(brain.id)
      assert :ok = run(source.id)
      {:ok, after_failure} = Brain.get_source(source.id, authorize?: false)
      assert after_failure.ingest_status == :failed

      # Re-stub with success and re-run: the worker accepts :failed as a
      # retry-eligible status.
      Req.Test.stub(IngestWorker, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html><body><p>Recovered.</p></body></html>")
      end)

      assert :ok = run(source.id)
      {:ok, recovered} = Brain.get_source(source.id, authorize?: false)
      assert recovered.ingest_status == :ingested
      assert recovered.ingested_content =~ "Recovered."
    end
  end

  describe "perform/1 idempotency" do
    test "skips sources already :ingested", %{brain: brain} do
      source =
        create_source(brain.id, %{
          ingest_status: :ingested,
          ingested_content: "Existing content.",
          ingested_at: DateTime.utc_now()
        })

      # No stub configured — if the worker hit the network we'd see a
      # `Req.Test` no-stub error. The :ok return proves it short-circuited.
      assert :ok = run(source.id)

      {:ok, reloaded} = Brain.get_source(source.id, authorize?: false)
      assert reloaded.ingest_status == :ingested
      assert reloaded.ingested_content == "Existing content."
    end

    test "no-ops when source row was deleted between enqueue and perform" do
      assert :ok = run(Ash.UUIDv7.generate())
    end
  end

  describe "EnqueueIngestWorker after_action" do
    test "Source :create enqueues IngestWorker for :pending rows", %{brain: brain} do
      {:ok, source} =
        Ash.create(
          Ash.Changeset.for_create(Brain.Source, :create, %{
            brain_id: brain.id,
            url: "https://example.com/new"
          }),
          authorize?: false
        )

      assert_enqueued(worker: IngestWorker, args: %{"source_id" => source.id})
    end

    test "Source :from_legacy_block does NOT enqueue when status is :ingested", %{brain: brain} do
      {:ok, source} =
        Ash.create(
          Ash.Changeset.for_create(Brain.Source, :from_legacy_block, %{
            brain_id: brain.id,
            url: "https://example.com/legacy-done",
            ingest_status: :ingested,
            ingested_content: "preserved",
            ingested_at: DateTime.utc_now()
          }),
          authorize?: false
        )

      refute_enqueued(worker: IngestWorker, args: %{"source_id" => source.id})
    end

    test "Source :from_legacy_block enqueues when status is :pending", %{brain: brain} do
      {:ok, source} =
        Ash.create(
          Ash.Changeset.for_create(Brain.Source, :from_legacy_block, %{
            brain_id: brain.id,
            url: "https://example.com/legacy-pending",
            ingest_status: :pending
          }),
          authorize?: false
        )

      assert_enqueued(worker: IngestWorker, args: %{"source_id" => source.id})
    end
  end
end
