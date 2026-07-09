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
end
