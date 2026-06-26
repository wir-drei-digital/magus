defmodule MagusWeb.Api.V2.SourcesControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Brain

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    {:ok, brain} = Brain.create_brain(%{title: "Hub"}, actor: user)
    %{user: user, plaintext: plaintext, brain: brain}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  describe "GET /api/v2/sources/:id" do
    test "returns the source row created from a body's source fence", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "WithSource"}, actor: user)

      body = """
      Reference:

      ```source
      url: https://example.com/article
      title: Example Article
      type: web
      ```
      """

      {:ok, _updated} =
        Brain.update_page_body(
          page,
          %{body: body, base_version: page.lock_version},
          actor: user
        )

      [source | _] =
        Magus.Brain.Source
        |> Ash.Query.filter(brain_id == ^brain.id)
        |> Ash.read!(actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/sources/#{source.id}")
        |> json_response(200)

      assert response["data"]["id"] == source.id
      assert response["data"]["url"] == "https://example.com/article"
      assert response["data"]["brain_id"] == brain.id

      assert response["data"]["ingest_status"] in [
               "pending",
               "ingesting",
               "ingested",
               "failed"
             ]
    end

    test "404 for unknown id", %{conn: conn, plaintext: plaintext} do
      response =
        conn |> auth(plaintext) |> get("/api/v2/sources/#{Ecto.UUID.generate()}")

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end
end
