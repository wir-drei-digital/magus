defmodule Magus.Integration.BrainApiV2E2ETest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  test "full external-agent workflow (create -> search -> read -> rename -> delete)", %{
    conn: conn
  } do
    user = generate(user())
    {token, plaintext} = api_token(actor: user, scope: :write)

    auth = fn c -> put_req_header(c, "authorization", "Bearer #{plaintext}") end

    # 1. Create brain
    %{"data" => brain} =
      conn |> auth.() |> post("/api/v2/brains", %{title: "E2E"}) |> json_response(201)

    # 2. Write a page with body
    %{"data" => page} =
      conn
      |> auth.()
      |> post("/api/v2/brains/#{brain["id"]}/pages", %{
        title: "Doc",
        body: "First paragraph mentioning Magus."
      })
      |> json_response(201)

    assert page["body"] =~ "First paragraph"
    assert is_integer(page["lock_version"])

    # 3. Search (text mode for determinism)
    %{"data" => hits} =
      conn
      |> auth.()
      |> post("/api/v2/brains/#{brain["id"]}/search", %{"query" => "Magus", "mode" => "text"})
      |> json_response(200)

    assert length(hits) >= 1

    # 4. Read back: body is returned directly (no ?format=markdown)
    %{"data" => fetched} =
      conn |> auth.() |> get("/api/v2/pages/#{page["id"]}") |> json_response(200)

    assert fetched["body"] =~ "First paragraph"
    assert fetched["id"] == page["id"]

    # 5. Update title
    %{"data" => renamed} =
      conn
      |> auth.()
      |> patch("/api/v2/pages/#{page["id"]}", %{title: "Renamed"})
      |> json_response(200)

    assert renamed["title"] == "Renamed"

    # 6. Update body via mode=append
    %{"data" => appended} =
      conn
      |> auth.()
      |> patch("/api/v2/pages/#{page["id"]}", %{body: "Second paragraph.", mode: "append"})
      |> json_response(200)

    assert appended["body"] =~ "First paragraph"
    assert appended["body"] =~ "Second paragraph"

    # 7. Soft-delete
    %{"data" => deleted} =
      conn |> auth.() |> delete("/api/v2/pages/#{page["id"]}") |> json_response(200)

    assert deleted["deleted_at"]

    # 8. Revoke and confirm 401
    {:ok, _} = Magus.Accounts.revoke_api_token(token, actor: user)

    conn = conn |> auth.() |> get("/api/v2/brains")
    assert json_response(conn, 401)["error"]["code"] == "invalid_token"
  end
end
