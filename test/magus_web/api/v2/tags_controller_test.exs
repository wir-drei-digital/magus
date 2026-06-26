defmodule MagusWeb.Api.V2.TagsControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    {:ok, brain} = Brain.create_brain(%{title: "Hub"}, actor: user)
    %{user: user, plaintext: plaintext, brain: brain}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  defp write_body(page, body, actor) do
    {:ok, updated} =
      Brain.update_page_body(
        page,
        %{body: body, base_version: page.lock_version},
        actor: actor
      )

    updated
  end

  describe "GET /api/v2/brains/:brain_id/tags" do
    test "returns deduped tag counts across pages", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      {:ok, p1} = Brain.create_page(brain.id, %{title: "Page1"}, actor: user)
      _ = write_body(p1, "First page mentions #alpha and #beta.", user)

      {:ok, p2} = Brain.create_page(brain.id, %{title: "Page2"}, actor: user)
      _ = write_body(p2, "Second page mentions #alpha.", user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{brain.id}/tags")
        |> json_response(200)

      tags = Enum.into(response["data"], %{}, &{&1["tag"], &1["count"]})
      assert tags["alpha"] == 2
      assert tags["beta"] == 1
    end

    test "404 for unknown brain", %{conn: conn, plaintext: plaintext} do
      response =
        conn |> auth(plaintext) |> get("/api/v2/brains/#{Ecto.UUID.generate()}/tags")

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end
end
