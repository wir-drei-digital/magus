defmodule Magus.Graph.Vector do
  @moduledoc """
  FalkorDB native vector index helpers.

  FalkorDB supports vector indices via `CREATE VECTOR INDEX` and KNN search
  via the `db.idx.vector.queryNodes` procedure. For a node to participate
  in a vector index, the indexed property must be stored as a FalkorDB
  vector type (`vecf32([...])`), not as a plain Cypher list. `Magus.Graph.Node`
  handles the wrapping automatically for numeric-list properties.
  """

  @doc """
  Create a vector index for `label.property`.

  Options:
    * `:dim` (required) — embedding dimension.
    * `:similarity` — `:cosine` (default), `:euclidean`, etc. Mapped to FalkorDB's
      uppercase `similarityFunction`.

  Idempotent: if an index already exists for the label/property, returns `:ok`.
  """
  def create_index(graph_name, label, property, opts) do
    dim = Keyword.fetch!(opts, :dim)
    similarity = Keyword.get(opts, :similarity, :cosine)
    sim_name = similarity |> Atom.to_string() |> String.upcase()

    cypher = """
    CREATE VECTOR INDEX FOR (n:#{label}) ON (n.#{property})
    OPTIONS {dimension: #{dim}, similarityFunction: '#{sim_name}'}
    """

    case Magus.Graph.query(graph_name, cypher) do
      {:ok, _} ->
        :ok

      {:error, %Redix.Error{message: msg}} ->
        if already_exists?(msg), do: :ok, else: {:error, msg}

      {:error, msg} when is_binary(msg) ->
        if already_exists?(msg), do: :ok, else: {:error, msg}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Create the vector index for `label.property` if it does not already exist.

  Idempotent and safe to call from any code path that is about to write
  embedded vectors: returns `{:ok, :created}` on first call and
  `{:ok, :already_exists}` on subsequent calls (or when FalkorDB surfaces
  an "already exists" error). Returns `{:error, reason}` only for real
  failures (graph unavailable, malformed options, etc.).

  Unlike `create_index/4`, this function preserves the distinction
  between "freshly created" and "already there", which lets callers log
  bootstrap activity once without spamming on every replay.
  """
  def ensure_index(graph_name, label, property, opts) do
    dim = Keyword.fetch!(opts, :dim)
    similarity = Keyword.get(opts, :similarity, :cosine)
    sim_name = similarity |> Atom.to_string() |> String.upcase()

    cypher = """
    CREATE VECTOR INDEX FOR (n:#{label}) ON (n.#{property})
    OPTIONS {dimension: #{dim}, similarityFunction: '#{sim_name}'}
    """

    case Magus.Graph.query(graph_name, cypher) do
      {:ok, _} ->
        {:ok, :created}

      {:error, %Redix.Error{message: msg}} ->
        if already_exists?(msg), do: {:ok, :already_exists}, else: {:error, msg}

      {:error, msg} when is_binary(msg) ->
        if already_exists?(msg), do: {:ok, :already_exists}, else: {:error, msg}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Find the `k` nearest neighbors of `query_vector` in `label.property`.

  Returns `{:ok, hits}` where each hit is the node's property map
  (including `id`) plus a `:score` key.

  Options:
    * `:k` — number of neighbors to return. Default: 10.
  """
  def knn_search(graph_name, label, property, query_vector, opts \\ []) do
    k = Keyword.get(opts, :k, 10)
    vec_literal = encode_vec(query_vector)

    cypher = """
    CALL db.idx.vector.queryNodes('#{label}', '#{property}', #{k}, vecf32(#{vec_literal}))
    YIELD node, score
    RETURN node, score
    """

    case Magus.Graph.query(graph_name, cypher) do
      {:ok, %{rows: rows}} ->
        hits = Enum.map(rows, fn [node, score] -> hit_from_row(node, score) end)
        {:ok, hits}

      {:error, _} = err ->
        err
    end
  end

  defp already_exists?(msg) when is_binary(msg) do
    msg =~ "already" or msg =~ "exists"
  end

  defp already_exists?(_), do: false

  defp encode_vec(list) when is_list(list) do
    "[" <>
      Enum.map_join(list, ", ", fn
        n when is_integer(n) -> Float.to_string(n * 1.0)
        f when is_float(f) -> Float.to_string(f)
      end) <>
      "]"
  end

  # FalkorDB returns nodes as a nested list of [key, value] pairs:
  #   [["id", 0], ["labels", ["Entity"]], ["properties", [["id", "e1"], ...]]]
  defp hit_from_row(node, score) do
    node
    |> node_to_map()
    |> Map.put(:score, score)
  end

  defp node_to_map(pairs) when is_list(pairs) do
    pairs
    |> Enum.reduce(%{}, fn
      ["properties", props], acc -> Map.merge(acc, properties_to_map(props))
      [key, value], acc -> Map.put(acc, atomize(key), value)
      _, acc -> acc
    end)
  end

  defp node_to_map(other), do: %{raw: other}

  defp properties_to_map(props) when is_list(props) do
    Enum.reduce(props, %{}, fn
      [k, v], acc -> Map.put(acc, atomize(k), v)
      _, acc -> acc
    end)
  end

  defp properties_to_map(_), do: %{}

  # Use to_existing_atom to avoid atom exhaustion DoS — node property names
  # are always created from known fields (callers build them as atom keys),
  # so they are guaranteed to exist by the time we decode results.
  defp atomize(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp atomize(key) when is_atom(key), do: key
end
