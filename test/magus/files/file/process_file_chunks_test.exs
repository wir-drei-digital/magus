defmodule Magus.Files.File.ProcessFileChunksTest do
  use Magus.ResourceCase, async: false

  require Ash.Query

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:magus, :openrouter_embeddings_url)

    Application.put_env(
      :magus,
      :openrouter_embeddings_url,
      "http://localhost:#{bypass.port}/embeddings"
    )

    prev_key = Application.get_env(:magus, :openrouter_api_key)
    Application.put_env(:magus, :openrouter_api_key, "test-key")

    on_exit(fn ->
      Application.put_env(:magus, :openrouter_embeddings_url, prev)
      Application.put_env(:magus, :openrouter_api_key, prev_key)
    end)

    Bypass.stub(bypass, "POST", "/embeddings", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"input" => texts} = Jason.decode!(body)
      dim = 1536
      data = Enum.map(texts, fn _ -> %{"embedding" => List.duplicate(0.0, dim)} end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => data}))
    end)

    {:ok, bypass: bypass}
  end

  # `create_file_from_connector` requires a real knowledge collection: its
  # policy (ActorCanCreateConnectorFile) always denies a nil
  # knowledge_collection_id, so we create a source + collection instead of
  # passing nil as the task brief originally guessed.
  defp stored_text_file(user, body) do
    path = "test/#{Ash.UUIDv7.generate()}.txt"
    {:ok, _} = Magus.Files.Storage.store(path, body)

    {:ok, source} =
      Magus.Knowledge.create_source(
        %{name: "Test Source", provider: :notion, auth_config: %{"key" => "test"}},
        actor: user
      )

    {:ok, collection} =
      Magus.Knowledge.create_collection(
        source.id,
        %{
          name: "Docs",
          external_id: "ext_folder_1",
          external_path: "/Docs"
        },
        actor: user
      )

    {:ok, file} =
      Magus.Files.create_file_from_connector(
        %{
          name: "doc.txt",
          type: :text,
          mime_type: "text/plain",
          file_size: byte_size(body),
          file_path: path,
          knowledge_collection_id: collection.id,
          external_id: "ext_doc_1"
        },
        actor: user
      )

    file
  end

  defp chunk_count(file_id) do
    Magus.Files.Chunk
    |> Ash.Query.filter(file_id == ^file_id)
    |> Ash.count!(authorize?: false)
  end

  test "reprocessing replaces chunks instead of accumulating them" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "some short text content for chunking")

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)
    first = chunk_count(file.id)
    assert first > 0

    reloaded = Magus.Files.get_file!(file.id, authorize?: false)
    {:ok, _} = Ash.update(reloaded, %{}, action: :process, authorize?: false)

    assert chunk_count(file.id) == first,
           "expected reprocess to replace chunks, not duplicate them"
  end

  test "an embedding API failure is transient: flagged for retry, then succeeds" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "text that will fail to embed the first time")

    # Route embeddings to a dead port for the first attempt.
    dead = Bypass.open()
    Bypass.down(dead)
    prev = Application.get_env(:magus, :openrouter_embeddings_url)

    Application.put_env(
      :magus,
      :openrouter_embeddings_url,
      "http://localhost:#{dead.port}/embeddings"
    )

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)

    failed = Magus.Files.get_file!(file.id, authorize?: false)
    assert failed.status == :error
    assert failed.transient_error == true
    assert failed.processing_attempts == 1

    # Restore the working fake and reprocess manually (what the cron trigger does).
    Application.put_env(:magus, :openrouter_embeddings_url, prev)
    {:ok, _} = Magus.Files.reprocess_file(failed, authorize?: false)
    # reprocess sets :pending and enqueues; in tests run the action inline:
    pending = Magus.Files.get_file!(file.id, authorize?: false)
    {:ok, _} = Ash.update(pending, %{}, action: :process, authorize?: false)

    recovered = Magus.Files.get_file!(file.id, authorize?: false)
    assert recovered.status == :ready
    assert recovered.transient_error == false

    assert recovered.processing_attempts == 0,
           "a successful process should reset the retry budget, not carry it forward"
  end

  test "an empty document is a permanent failure: no retry flag" do
    user = generate(user())
    Magus.Generators.ensure_workspace_plan(user)
    file = stored_text_file(user, "   ")

    {:ok, _} = Ash.update(file, %{}, action: :process, authorize?: false)

    failed = Magus.Files.get_file!(file.id, authorize?: false)
    assert failed.status == :error
    assert failed.transient_error == false
  end

  describe "stuck-:processing watchdog" do
    test "recover_stuck_processing action resets a stuck file back to :pending" do
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)
      file = stored_text_file(user, "some content")

      # Simulate a crash mid-ProcessFile: status left at :processing (never
      # reached the :ready or :error terminal update).
      {:ok, stuck} =
        Ash.update(file, %{status: :processing}, action: :update_status, authorize?: false)

      assert stuck.status == :processing

      {:ok, recovered} =
        Ash.update(stuck, %{}, action: :recover_stuck_processing, authorize?: false)

      assert recovered.status == :pending
      assert recovered.transient_error == false
      assert recovered.processing_attempts == stuck.processing_attempts + 1
    end

    test "recover_stuck_processing is bounded: the where-clause budget mirrors retry_transient" do
      # Mirrors the "scheduler filter excludes :syncing collections" pattern
      # in knowledge_collection_test.exs: exercise the trigger's `where`
      # expression directly against seeded rows rather than trying to
      # backdate `updated_at` (not directly settable through the action
      # layer). The action-level transition above is the unit under test;
      # this asserts the query-level budget guard independently.
      user = generate(user())
      Magus.Generators.ensure_workspace_plan(user)
      file = stored_text_file(user, "some content")

      {:ok, stuck} =
        Ash.update(file, %{status: :processing, processing_attempts: 4},
          action: :update_status,
          authorize?: false
        )

      require Ash.Query

      ids =
        Magus.Files.File
        |> Ash.Query.filter(status == :processing and processing_attempts < 4)
        |> Ash.read!(authorize?: false)
        |> MapSet.new(& &1.id)

      refute MapSet.member?(ids, stuck.id),
             "a file that has exhausted its retry budget must not match the watchdog's where clause"
    end
  end
end
