defmodule MagusWeb.Api.V2.BrainsControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    %{user: user, plaintext: plaintext}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  describe "GET /api/v2/brains" do
    test "lists brains for the token's actor", %{conn: conn, user: user, plaintext: plaintext} do
      {:ok, b1} = Magus.Brain.create_brain(%{title: "Alpha"}, actor: user)
      {:ok, b2} = Magus.Brain.create_brain(%{title: "Beta"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains")
        |> json_response(200)

      titles = Enum.map(response["data"], & &1["title"])
      assert "Alpha" in titles
      assert "Beta" in titles
      assert b1.id in Enum.map(response["data"], & &1["id"])
      assert b2.id in Enum.map(response["data"], & &1["id"])
    end

    test "401 with no token", %{conn: conn} do
      conn = get(conn, "/api/v2/brains")
      assert json_response(conn, 401)["error"]["code"] == "missing_token"
    end
  end

  describe "POST /api/v2/brains" do
    test "creates a brain with the given title", %{conn: conn, plaintext: plaintext} do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/brains", %{title: "New Brain", description: "Test"})
        |> json_response(201)

      assert response["data"]["title"] == "New Brain"
      assert response["data"]["slug"] =~ "new-brain"
    end

    test "403 with a read-only token", %{conn: conn, user: user} do
      {_read_token, ro_plaintext} = api_token(actor: user, scope: :read)

      conn =
        conn
        |> auth(ro_plaintext)
        |> post("/api/v2/brains", %{title: "Should fail"})

      assert json_response(conn, 403)["error"]["code"] == "insufficient_scope"
    end
  end

  describe "GET /api/v2/brains/:id" do
    test "returns the brain by id", %{conn: conn, user: user, plaintext: plaintext} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Show me"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{brain.id}")
        |> json_response(200)

      assert response["data"]["id"] == brain.id
    end

    test "404 for unknown id", %{conn: conn, plaintext: plaintext} do
      conn =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns the brain by slug", %{conn: conn, user: user, plaintext: plaintext} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Slug Lookup"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{brain.slug}")
        |> json_response(200)

      assert response["data"]["id"] == brain.id
      assert response["data"]["slug"] == brain.slug
    end
  end

  describe "PATCH /api/v2/brains/:id" do
    test "updates title", %{conn: conn, user: user, plaintext: plaintext} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Old"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> patch("/api/v2/brains/#{brain.id}", %{title: "New"})
        |> json_response(200)

      assert response["data"]["title"] == "New"
    end
  end

  describe "DELETE /api/v2/brains/:id" do
    test "archives the brain", %{conn: conn, user: user, plaintext: plaintext} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Goner"}, actor: user)

      conn =
        conn
        |> auth(plaintext)
        |> delete("/api/v2/brains/#{brain.id}")

      assert response(conn, 204)

      refute_brain_in_list(user, brain.id)
    end
  end

  defp refute_brain_in_list(user, brain_id) do
    {:ok, brains} = Magus.Brain.list_brains(actor: user)
    refute Enum.any?(brains, &(&1.id == brain_id))
  end
end
