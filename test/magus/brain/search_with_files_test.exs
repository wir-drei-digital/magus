defmodule Magus.Brain.SearchWithFilesTest do
  @moduledoc """
  Covers the unified semantic search across page chunks, source chunks,
  and file chunks after the C5 cutover. Hits now carry
  `kind: :page_chunk | :source_chunk | :file_chunk` rather than the
  pre-cutover `:block`.
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.PageChunk
  alias Magus.Brain.SourceChunk
  alias Magus.Files

  @embedding_dim 1536

  setup do
    user = generate(user()) |> ensure_workspace_plan()
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  defp embedding, do: List.duplicate(0.1, @embedding_dim)

  defp insert_page_chunk!(page_id, content, embedding, index \\ 0) do
    PageChunk
    |> Ash.Changeset.for_create(:create, %{
      page_id: page_id,
      index: index,
      content: content,
      token_count: 4,
      embedding: embedding
    })
    |> Ash.create!(authorize?: false)
  end

  defp delete_page_chunks!(page_id) do
    require Ash.Query

    PageChunk
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(&Ash.destroy!(&1, authorize?: false))
  end

  defp insert_source_chunk!(source_id, content, embedding) do
    SourceChunk
    |> Ash.Changeset.for_create(:create, %{
      source_id: source_id,
      index: 0,
      content: content,
      token_count: 4,
      embedding: embedding
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_file!(user, name) do
    {:ok, file} =
      Files.create_file(
        %{
          name: name,
          type: :document,
          mime_type: "application/pdf",
          file_size: 1024,
          file_path: "tmp/" <> name,
          workspace_id: nil
        },
        actor: user
      )

    file
  end

  defp link_file_in_body!(page, file_id, user) do
    body = "Some intro.\n\n[📎 report](magus://file/#{file_id})\n"

    Brain.update_page_body(
      page,
      %{body: body, base_version: page.lock_version},
      actor: user
    )
  end

  test "returns page_chunk and file_chunk hits unified", %{
    user: user,
    brain: brain,
    page: page
  } do
    emb = embedding()

    file = create_file!(user, "report.pdf")
    {:ok, updated_page} = link_file_in_body!(page, file.id, user)

    # Wipe derived chunks (no embeddings on them yet) and insert a chunk
    # with an embedding so semantic search can return it deterministically.
    delete_page_chunks!(updated_page.id)
    insert_page_chunk!(updated_page.id, "Q3 revenue was 5M", emb)

    {:ok, _chunk} =
      Files.create_chunk(
        %{
          file_id: file.id,
          content: "Q3 revenue topped projections at 5M",
          embedding: emb,
          position: 0,
          token_count: 8
        },
        authorize?: false
      )

    results = Brain.search_with_files(brain.id, emb, limit: 10, actor: user)

    kinds = results |> Enum.map(& &1.kind) |> Enum.uniq()
    assert :page_chunk in kinds
    assert :file_chunk in kinds

    page_hit = Enum.find(results, &(&1.kind == :page_chunk))
    assert page_hit.page_id == page.id
    assert page_hit.brain_id == brain.id
    assert page_hit.snippet =~ "Q3 revenue"
    assert is_float(page_hit.score)

    file_hit = Enum.find(results, &(&1.kind == :file_chunk))
    assert file_hit.file_id == file.id
    assert file_hit.page_id == page.id
    assert file_hit.snippet =~ "Q3 revenue"
  end

  test "returns source_chunk hits from ingested sources", %{
    user: user,
    brain: brain
  } do
    emb = embedding()

    {:ok, source} =
      Magus.Brain.Source
      |> Ash.Changeset.for_create(:create, %{
        brain_id: brain.id,
        url: "https://example.com/post"
      })
      |> Ash.create(authorize?: false)

    insert_source_chunk!(source.id, "Source content about Elixir", emb)

    results = Brain.search_with_files(brain.id, emb, limit: 10, actor: user)

    source_hit = Enum.find(results, &(&1.kind == :source_chunk))
    assert source_hit
    assert source_hit.source_id == source.id
    assert source_hit.brain_id == brain.id
    assert source_hit.snippet =~ "Elixir"
  end

  test "excludes file_chunks for files not referenced in any body of the brain", %{
    user: user,
    brain: brain,
    page: page
  } do
    emb = embedding()

    other_file = create_file!(user, "unused.pdf")

    {:ok, _orphan_chunk} =
      Files.create_chunk(
        %{
          file_id: other_file.id,
          content: "irrelevant",
          embedding: emb,
          position: 0,
          token_count: 1
        },
        authorize?: false
      )

    insert_page_chunk!(page.id, "Q3 revenue", emb)

    results = Brain.search_with_files(brain.id, emb, limit: 10, actor: user)

    refute Enum.any?(results, &(&1.kind == :file_chunk and &1.file_id == other_file.id))
  end

  test "returns only page_chunk hits when no files or sources are referenced", %{
    user: user,
    brain: brain,
    page: page
  } do
    emb = embedding()

    insert_page_chunk!(page.id, "Just a paragraph", emb)

    results = Brain.search_with_files(brain.id, emb, limit: 10, actor: user)

    refute Enum.empty?(results)
    assert Enum.all?(results, &(&1.kind == :page_chunk))
  end

  test "respects the limit parameter", %{user: user, brain: brain, page: page} do
    emb = embedding()

    Enum.each(1..3, fn i ->
      {:ok, chunk_page} = Brain.create_page(brain.id, %{title: "Extra #{i}"}, actor: user)
      insert_page_chunk!(chunk_page.id, "Page chunk #{i}", emb)
    end)

    insert_page_chunk!(page.id, "Original chunk", emb)

    results = Brain.search_with_files(brain.id, emb, limit: 2, actor: user)
    assert length(results) == 2
  end
end
