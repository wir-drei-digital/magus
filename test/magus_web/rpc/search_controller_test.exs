defmodule MagusWeb.Rpc.SearchControllerTest do
  @moduledoc """
  Exercises the unified search controller (`GET /rpc/search`) used by the
  SvelteKit /search route: query handling, type filtering, and actor scoping.
  The ranking/orchestration itself is covered by Magus.SearchTest.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  alias Magus.Chat

  defp search(conn, user, path) do
    conn
    |> log_in_user(user)
    |> get(path)
    |> json_response(200)
  end

  test "short queries return no results", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => []} = search(conn, user, "/rpc/search?q=a")
  end

  test "finds a conversation by title", %{conn: conn} do
    user = generate(user())

    {:ok, conversation} =
      Chat.create_conversation(%{title: "Unique Zebra Discussion"}, actor: user)

    assert %{"success" => true, "data" => data} =
             search(conn, user, "/rpc/search?q=zebra")

    hit = Enum.find(data, &(&1["id"] == conversation.id))
    assert hit["type"] == "conversation"
    assert hit["title"] == "Unique Zebra Discussion"
    assert hit["snippet"]
  end

  test "the type filter restricts results to that type", %{conn: conn} do
    user = generate(user())
    {:ok, _conversation} = Chat.create_conversation(%{title: "Walrus Planning"}, actor: user)

    assert %{"success" => true, "data" => data} =
             search(conn, user, "/rpc/search?q=walrus&type=conversation")

    assert data != []
    assert Enum.all?(data, &(&1["type"] == "conversation"))
  end

  test "does not surface another user's conversation", %{conn: conn} do
    owner = generate(user())
    stranger = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "Secret Narwhal Notes"}, actor: owner)

    assert %{"success" => true, "data" => data} =
             search(conn, stranger, "/rpc/search?q=narwhal")

    refute Enum.any?(data, &(&1["id"] == conversation.id))
  end

  test "unauthenticated requests are rejected", %{conn: conn} do
    conn = get(conn, "/rpc/search?q=zebra")
    assert conn.status in [401, 302]
  end
end
