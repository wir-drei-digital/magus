defmodule MagusWeb.Rpc.SearchController do
  @moduledoc """
  Unified full-text search for the SvelteKit `/search` route
  (`GET /rpc/search?q=&type=`). Runs in the session-authenticated `:rpc`
  pipeline and delegates to `Magus.Search.search/2` — the same parallel,
  policy-scoped orchestrator the classic search page uses — so ranking and
  per-type authorization are identical. Snippets are HTML-escaped server-side
  with only `<mark>` highlight tags injected. Response mirrors the
  AshTypescript RPC envelope (`{success, data | errors}`).
  """
  use MagusWeb, :controller

  @all_types [:message, :conversation, :prompt, :resource, :chunk]

  def search(conn, params) do
    user = conn.assigns.current_user
    query = to_string(params["q"] || "")
    types = parse_types(params["type"])

    # Magus.Search.search/2 always returns {:ok, results} (per-type failures are
    # rescued internally to []), so match it directly.
    {:ok, results} = Magus.Search.search(query, actor: user, types: types)
    json(conn, %{success: true, data: Enum.map(results, &serialize/1)})
  end

  # Explicit string→atom mapping (no String.to_atom on user input); unknown or
  # "all" falls back to every type.
  defp parse_types("message"), do: [:message]
  defp parse_types("conversation"), do: [:conversation]
  defp parse_types("prompt"), do: [:prompt]
  defp parse_types("resource"), do: [:resource]
  defp parse_types("chunk"), do: [:chunk]
  defp parse_types(_), do: @all_types

  defp serialize(result) do
    %{
      type: result.type,
      id: result.id,
      title: result.title,
      snippet: result.snippet,
      score: result.score,
      metadata: result.metadata
    }
  end
end
