defmodule MagusWeb.Api.V2.SearchControllerTest do
  @moduledoc """
  Covers POST /api/v2/brains/:brain_id/search after the C5f chunk-based
  rewrite. The controller now returns hits with `kind: "page" |
  "page_chunk" | "source_chunk" | "file_chunk"` — never `"block"`.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    {:ok, brain} = Brain.create_brain(%{title: "Hub"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

    # Body containing distinctive tokens so the FTS index has something
    # deterministic to match against.
    {:ok, page} =
      Brain.update_page_body(
        page,
        %{body: "apple orange banana\n\ncherry pie recipe", base_version: page.lock_version},
        actor: user
      )

    %{user: user, plaintext: plaintext, brain: brain, page: page}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  describe "POST /api/v2/brains/:brain_id/search (mode: text)" do
    test "returns matching pages with the new shape", %{
      conn: conn,
      brain: brain,
      plaintext: plaintext,
      page: page
    } do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{
          "query" => "apple",
          "mode" => "text",
          "limit" => 5
        })
        |> json_response(200)

      assert is_list(response["data"])
      assert length(response["data"]) >= 1
      hit = hd(response["data"])
      # New shape: text hits are `:page`, NOT `:block`.
      assert hit["kind"] == "page"
      assert hit["page_id"] == page.id
      assert hit["brain_id"] == brain.id
      assert hit["title"] == "Notes"
      assert hit["snippet"] =~ "apple"
      assert is_number(hit["rank"])
    end

    test "accepts the brain slug as well as the id", %{
      conn: conn,
      brain: brain,
      plaintext: plaintext,
      page: page
    } do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.slug}/search", %{
          "query" => "apple",
          "mode" => "text",
          "limit" => 5
        })
        |> json_response(200)

      assert is_list(response["data"])
      assert length(response["data"]) >= 1
      hit = hd(response["data"])
      assert hit["kind"] == "page"
      assert hit["page_id"] == page.id
    end

    test "returns an empty list when nothing matches", %{
      conn: conn,
      brain: brain,
      plaintext: plaintext
    } do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{
          "query" => "zzznoneofitmatchesxyz",
          "mode" => "text"
        })
        |> json_response(200)

      assert response["data"] == []
    end
  end

  describe "validation errors" do
    test "400 when query is missing or empty", %{
      conn: conn,
      brain: brain,
      plaintext: plaintext
    } do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{"mode" => "text"})

      assert json_response(response, 400)["error"]["code"] == "invalid_request"

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{"query" => "", "mode" => "text"})

      assert json_response(response, 400)["error"]["code"] == "invalid_request"
    end

    test "400 when kind is unrecognized", %{
      conn: conn,
      brain: brain,
      plaintext: plaintext
    } do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{
          "query" => "apple",
          "kind" => "weird"
        })

      assert json_response(response, 400)["error"]["code"] == "invalid_request"
    end
  end

  describe "auth errors" do
    test "404 for unknown brain", %{conn: conn, plaintext: plaintext} do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains/#{Ecto.UUID.generate()}/search", %{
          "query" => "anything",
          "mode" => "text"
        })

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end

    test "403 for cross-workspace token", %{conn: conn, user: user, brain: brain} do
      ws = generate(workspace(actor: user))
      {_t, other_ws_plaintext} = api_token(actor: user, scope: :write, workspace_id: ws.id)

      response =
        conn
        |> auth(other_ws_plaintext)
        |> post("/api/v2/brains/#{brain.id}/search", %{
          "query" => "apple",
          "mode" => "text"
        })

      assert json_response(response, 403)["error"]["code"] == "workspace_mismatch"
    end
  end
end
