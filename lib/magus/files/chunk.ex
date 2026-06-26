defmodule Magus.Files.Chunk do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Files,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @doc false
  # Enqueues a Super Brain extraction job for this chunk after the row
  # commits. ExtractFileChunk filters out non-extractable file types
  # (image/video) in `load/1`, so this fires unconditionally and lets
  # the worker no-op on incompatible file types.
  def enqueue_super_brain_extraction(chunk_id) when is_binary(chunk_id) do
    if Magus.SuperBrain.enabled?() do
      %{"resource_id" => chunk_id}
      |> Magus.SuperBrain.Workers.ExtractFileChunk.new()
      |> Oban.insert()
    else
      :ok
    end
  end

  postgres do
    table "file_chunks"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :for_file do
      argument :file_id, :uuid, allow_nil?: false
      filter expr(file_id == ^arg(:file_id))
      prepare build(sort: [position: :asc])
    end

    read :semantic_search do
      argument :query_embedding, {:array, :float}, allow_nil?: false
      argument :file_ids, {:array, :uuid}, allow_nil?: false
      argument :limit, :integer, default: 10

      prepare fn query, _context ->
        require Ash.Query

        embedding = Ash.Query.get_argument(query, :query_embedding)
        file_ids = Ash.Query.get_argument(query, :file_ids)
        limit = Ash.Query.get_argument(query, :limit)

        # Resolve top-N chunk ids via raw Ecto with a parameterized
        # vector. Going through the `vector_distance` calc + sort path
        # makes AshPostgres inline the 1536-dim embedding into the SQL
        # string as `ARRAY[float, ...]::vector`, which OOMs Postgres on
        # any meaningful chunk count. The Pgvector binary parameter
        # below lets the planner use the HNSW index instead.
        ordered_ids = top_chunk_ids(embedding, file_ids, limit)

        if ordered_ids == [] do
          Ash.Query.filter(query, false)
        else
          query
          |> Ash.Query.filter(id in ^ordered_ids)
          |> Ash.Query.after_action(fn _q, chunks ->
            by_id = Map.new(chunks, &{&1.id, &1})

            ordered =
              Enum.flat_map(ordered_ids, fn id ->
                case Map.get(by_id, id) do
                  nil -> []
                  chunk -> [chunk]
                end
              end)

            {:ok, ordered}
          end)
        end
      end
    end

    read :fulltext_search do
      description "Full-text search across file chunks using PostgreSQL tsvector + pg_trgm"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, _context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)

        # Use ILIKE for basic matching and pg_trgm similarity for fuzzy matching
        # Note: file_chunks doesn't have a search_vector column (conflicts with pgvector)
        query
        |> Ash.Query.filter(
          fragment(
            "content ILIKE ? OR similarity(content, ?) > 0.3",
            ^"%#{search_term}%",
            ^search_term
          )
        )
        |> Ash.Query.load(:file)
      end
    end

    create :create do
      accept [:file_id, :content, :position, :token_count, :metadata, :embedding]

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, chunk ->
          enqueue_super_brain_extraction(chunk.id)
          {:ok, chunk}
        end)
      end
    end

    create :bulk_create do
      accept [:file_id, :content, :position, :token_count, :metadata, :embedding]
      argument :chunks, {:array, :map}, allow_nil?: false

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, chunk ->
          enqueue_super_brain_extraction(chunk.id)
          {:ok, chunk}
        end)
      end
    end
  end

  policies do
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if {Magus.Files.File.Checks.ActorCanReadFile, via: :file}
    end

    # Chunks are only written by the file-processing pipeline, which calls
    # through `authorize?: false`. Deny user-facing writes so any accidental
    # `actor:` caller fails loud instead of silently succeeding.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :content, :string do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
    end

    attribute :token_count, :integer do
      allow_nil? false
    end

    attribute :metadata, :map do
      default %{}
    end

    attribute :embedding, Magus.Files.Types.Vector do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :file, Magus.Files.File do
      allow_nil? false
    end
  end

  calculations do
    calculate :vector_distance, :float do
      argument :query_embedding, {:array, :float}, allow_nil?: false

      # Cosine distance using pgvector <=> operator
      # The query embedding (float array) needs to be cast to vector
      calculation expr(fragment("(embedding <=> ?::vector)", ^arg(:query_embedding)))
    end
  end

  # Raw-Ecto top-N by cosine distance, vector passed as a single
  # Pgvector binary parameter so the HNSW index is usable and the
  # SQL string stays small. Returns chunk ids in distance order.
  defp top_chunk_ids([], _file_ids, _limit), do: []
  defp top_chunk_ids(_embedding, [], _limit), do: []

  defp top_chunk_ids(embedding, file_ids, limit) do
    import Ecto.Query

    vector = Pgvector.new(embedding)

    file_id_bins =
      Enum.map(file_ids, fn
        <<_::128>> = bin -> bin
        s when is_binary(s) -> Ecto.UUID.dump!(s)
      end)

    from(c in "file_chunks",
      where: not is_nil(c.embedding),
      where: c.file_id in ^file_id_bins,
      select: c.id,
      order_by: [asc: fragment("? <=> ?", c.embedding, ^vector)],
      limit: ^limit
    )
    |> Magus.Repo.all()
    |> Enum.map(&Ecto.UUID.load!/1)
  end
end
