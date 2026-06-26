defmodule MagusWeb.Api.V2.SearchController do
  @moduledoc """
  Search across brain pages, sources, and (optionally) the file chunks
  referenced from page bodies.

  POST `/api/v2/brains/:brain_id/search` body:

      {
        "query": "string, required",
        "kind":  "unified" | "semantic" | "text",  # default "unified"
        "limit": integer (1..50, default 10),
        "cross_brain": true   # optional — span every accessible brain
      }

  - `unified` (default) — `Magus.Brain.search_with_files/3`; mixes
    `:page_chunk` + `:source_chunk` + `:file_chunk` hits.
  - `semantic` — `Magus.Brain.search_chunks/3`; chunk hits only,
    no file scan.
  - `text` — `Magus.Brain.search_pages_text/3`; FTS over
    `brain_pages.search_vector`, no embedding generated.

  Pass `?cross_brain=true` (or `brain_scope=all`) to span every brain
  the actor can access. In that mode the `:brain_id` path segment is
  still required for routing and workspace-match enforcement, but the
  search itself ignores it.

  When embedding generation fails (no API key configured, network
  error) the controller returns an empty result set instead of failing
  the request so callers always receive a valid response shape.
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  alias Magus.Brain
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  @default_limit 10
  @max_limit 50

  def search(conn, %{"brain_id" => brain_id} = params) do
    user = conn.assigns.current_user
    query = params["query"]
    kind = params["kind"] || params["mode"] || "unified"
    limit = parse_limit(params["limit"])
    cross_brain? = cross_brain?(params)

    with :ok <- validate_query(query),
         :ok <- validate_kind(kind),
         {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id) do
      scope_brain_id = if cross_brain?, do: nil, else: brain.id
      hits = do_search(scope_brain_id, query, kind, limit, user)
      json(conn, ApiView.data(Enum.map(hits, &serialize/1)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      {:error, :invalid_query} -> bad_request(conn, "Query is required")
      {:error, :invalid_kind} -> bad_request(conn, "Kind must be one of: unified, semantic, text")
      _ -> not_found(conn)
    end
  end

  defp validate_query(q) when is_binary(q) do
    if String.trim(q) == "", do: {:error, :invalid_query}, else: :ok
  end

  defp validate_query(_), do: {:error, :invalid_query}

  # `hybrid` is preserved for backwards-compat with the block-era controller.
  defp validate_kind(kind) when kind in ["unified", "semantic", "text", "hybrid"], do: :ok
  defp validate_kind(_), do: {:error, :invalid_kind}

  defp cross_brain?(params) do
    case Map.get(params, "cross_brain") do
      true ->
        true

      "true" ->
        true

      _ ->
        Map.get(params, "brain_scope") == "all"
    end
  end

  defp parse_limit(nil), do: @default_limit
  defp parse_limit(n) when is_integer(n), do: clamp_limit(n)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> clamp_limit(n)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp clamp_limit(n), do: n |> max(1) |> min(@max_limit)

  defp do_search(brain_id, query, "text", limit, user) do
    Brain.search_pages_text(brain_id, query, limit: limit, actor: user)
  end

  defp do_search(brain_id, query, "semantic", limit, user) do
    case embed_query(query) do
      {:ok, embedding} -> Brain.search_chunks(brain_id, embedding, limit: limit, actor: user)
      :error -> []
    end
  end

  defp do_search(brain_id, query, kind, limit, user) when kind in ["unified", "hybrid"] do
    case embed_query(query) do
      {:ok, embedding} -> Brain.search_with_files(brain_id, embedding, limit: limit, actor: user)
      :error -> []
    end
  end

  defp embed_query(query) do
    case Magus.Files.EmbeddingModel.embed(query) do
      {:ok, vec} when is_list(vec) -> {:ok, vec}
      _ -> :error
    end
  end

  defp serialize(%{kind: :page_chunk} = hit) do
    %{
      kind: "page_chunk",
      score: hit.score,
      brain_id: hit.brain_id,
      page_id: hit.page_id,
      snippet: hit.snippet
    }
  end

  defp serialize(%{kind: :source_chunk} = hit) do
    %{
      kind: "source_chunk",
      score: hit.score,
      brain_id: hit.brain_id,
      source_id: hit.source_id,
      snippet: hit.snippet
    }
  end

  defp serialize(%{kind: :file_chunk} = hit) do
    %{
      kind: "file_chunk",
      score: hit.score,
      brain_id: hit.brain_id,
      page_id: hit.page_id,
      file_id: hit.file_id,
      snippet: hit.snippet
    }
  end

  defp serialize(%{kind: :page} = hit) do
    %{
      kind: "page",
      rank: hit.rank,
      brain_id: hit.brain_id,
      page_id: hit.page_id,
      title: hit.title,
      snippet: hit.snippet
    }
  end

  defp bad_request(conn, msg) do
    conn
    |> put_status(:bad_request)
    |> json(ApiView.error("invalid_request", msg))
  end
end
