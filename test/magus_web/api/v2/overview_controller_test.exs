defmodule MagusWeb.Api.V2.OverviewControllerTest do
  @moduledoc """
  Covers the `/api/v2` brain task overview (Task 11): the cross-plan rollup of
  non-archived tasks + recent activity. Tenancy: a stranger gets 404 (the brain
  is filtered out by the Ash policy), a wrong-workspace token gets 403
  (`RequireWorkspaceMatch`), an accessible brain gets 200.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Plan

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    brain = generate(brain(user_id: user.id))
    p1 = brain_page(brain_id: brain.id, user_id: user.id)
    p2 = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, plaintext: plaintext, brain: brain, p1: p1, p2: p2}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  describe "GET /api/v2/brains/:brain_id/overview" do
    test "returns the rollup of tasks and activity (200)", %{
      conn: conn,
      user: user,
      brain: brain,
      p1: p1,
      p2: p2,
      plaintext: plaintext
    } do
      {:ok, _} = Plan.create_plan_task(p1.id, %{title: "a"}, actor: user)
      {:ok, t2} = Plan.create_plan_task(p2.id, %{title: "b"}, actor: user)
      {:ok, _} = Plan.claim_task(t2, %{assigned_to_agent: "claude-code"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{brain.id}/overview")
        |> json_response(200)

      assert length(response["data"]["tasks"]) == 2
      assert response["data"]["activity"] != []

      page_ids = Enum.map(response["data"]["tasks"], & &1["brain_page_id"])
      assert p1.id in page_ids
      assert p2.id in page_ids
    end

    test "a stranger gets 404", %{conn: conn, brain: brain} do
      stranger = generate(user())
      {_t, stranger_plaintext} = api_token(actor: stranger, scope: :write)

      response =
        conn
        |> auth(stranger_plaintext)
        |> get("/api/v2/brains/#{brain.id}/overview")

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end

    test "a wrong-workspace token gets 403", %{conn: conn, user: user, brain: brain} do
      # The brain is personal (workspace_id == nil); a workspace-scoped token
      # mismatches -> 403 workspace_mismatch.
      ws = generate(workspace(actor: user))
      {_t, other_ws_plaintext} = api_token(actor: user, scope: :write, workspace_id: ws.id)

      response =
        conn
        |> auth(other_ws_plaintext)
        |> get("/api/v2/brains/#{brain.id}/overview")

      assert json_response(response, 403)["error"]["code"] == "workspace_mismatch"
    end
  end
end
