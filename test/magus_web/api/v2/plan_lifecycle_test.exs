defmodule MagusWeb.Api.V2.PlanLifecycleTest do
  @moduledoc """
  Covers the `/api/v2` plan delivery lifecycle surface (Task 10): deliver /
  undeliver / show with `lifecycle` + `delivered_at` + `delivery_ref`, the
  stranded-plan detector, and the spec-link set/read.

  Tenancy mirrors the task surface: the Ash brain-access policy (actor scoped)
  plus `RequireWorkspaceMatch` (token workspace vs the page's brain workspace).
  The deliver/undeliver/spec actions are editor-gated at the resource layer.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Plan

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    brain = generate(brain(user_id: user.id))
    %{user: user, plaintext: plaintext, brain: brain}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  # A `:plan` page whose single task is `:done`, so its computed lifecycle is
  # `:done` (the stranding precondition).
  defp done_plan(brain, user, title \\ "Done plan") do
    page = brain_page(brain_id: brain.id, user_id: user.id, title: title)
    {:ok, plan} = Brain.set_page_kind(page, :plan, actor: user)
    {:ok, task} = Plan.create_plan_task(plan.id, %{title: "Work"}, actor: user)
    {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)
    plan
  end

  defp plan_page(brain, user, title) do
    page = brain_page(brain_id: brain.id, user_id: user.id, title: title)
    {:ok, plan} = Brain.set_page_kind(page, :plan, actor: user)
    plan
  end

  describe "POST /api/v2/plans/:id/deliver" do
    test "marks a plan delivered (200, lifecycle delivered)", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = done_plan(brain, user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{plan.id}/deliver", %{"delivery_ref" => "v1.2.3"})
        |> json_response(200)

      assert response["data"]["id"] == plan.id
      assert response["data"]["lifecycle"] == "delivered"
      assert response["data"]["delivery_ref"] == "v1.2.3"
      assert response["data"]["delivered_at"]
    end

    test "delivers without a delivery_ref", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = done_plan(brain, user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{plan.id}/deliver", %{})
        |> json_response(200)

      assert response["data"]["lifecycle"] == "delivered"
      assert response["data"]["delivery_ref"] == nil
    end

    test "404 for an unknown plan id", %{conn: conn, plaintext: plaintext} do
      response =
        conn |> auth(plaintext) |> post("/api/v2/plans/#{Ecto.UUID.generate()}/deliver", %{})

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v2/plans/:id/undeliver" do
    test "returns the plan to its computed lifecycle (done)", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = done_plan(brain, user)
      {:ok, _} = Brain.mark_page_delivered(plan, %{delivery_ref: "tag"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{plan.id}/undeliver", %{})
        |> json_response(200)

      assert response["data"]["lifecycle"] == "done"
      assert response["data"]["delivered_at"] == nil
      assert response["data"]["delivery_ref"] == nil
    end
  end

  describe "GET /api/v2/plans/:id" do
    test "includes lifecycle, delivered_at, delivery_ref, spec_page_id, kind", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = done_plan(brain, user)
      {:ok, _} = Brain.mark_page_delivered(plan, %{delivery_ref: "ship-1"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/plans/#{plan.id}")
        |> json_response(200)

      assert response["data"]["id"] == plan.id
      assert response["data"]["title"] == "Done plan"
      assert response["data"]["kind"] == "plan"
      assert response["data"]["lifecycle"] == "delivered"
      assert response["data"]["delivery_ref"] == "ship-1"
      assert response["data"]["delivered_at"]
      assert Map.has_key?(response["data"], "spec_page_id")
    end

    test "404 for an unknown id", %{conn: conn, plaintext: plaintext} do
      response = conn |> auth(plaintext) |> get("/api/v2/plans/#{Ecto.UUID.generate()}")
      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v2/plans/:id/spec" do
    test "links a plan to its spec page (200)", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = plan_page(brain, user, "Impl plan")
      spec = brain_page(brain_id: brain.id, user_id: user.id, title: "Spec")
      {:ok, spec} = Brain.set_page_kind(spec, :spec, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{plan.id}/spec", %{"spec_page_id" => spec.id})
        |> json_response(200)

      assert response["data"]["id"] == plan.id
      assert response["data"]["spec_page_id"] == spec.id
    end

    test "clears the spec link with a null spec_page_id", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      plan = plan_page(brain, user, "Linked plan")
      spec = brain_page(brain_id: brain.id, user_id: user.id, title: "Spec2")
      {:ok, spec} = Brain.set_page_kind(spec, :spec, actor: user)
      {:ok, _} = Brain.set_page_spec(plan, spec.id, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{plan.id}/spec", %{"spec_page_id" => nil})
        |> json_response(200)

      assert response["data"]["spec_page_id"] == nil
    end
  end

  describe "GET /api/v2/brains/:brain_id/stranded" do
    test "returns done-not-delivered plans, excludes delivered ones", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      stranded = done_plan(brain, user, "Stranded")

      delivered = done_plan(brain, user, "Delivered")
      {:ok, _} = Brain.mark_page_delivered(delivered, %{}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/brains/#{brain.id}/stranded")
        |> json_response(200)

      ids = Enum.map(response["data"], & &1["id"])
      assert stranded.id in ids
      refute delivered.id in ids
    end

    test "404 for an unknown brain", %{conn: conn, plaintext: plaintext} do
      response =
        conn |> auth(plaintext) |> get("/api/v2/brains/#{Ecto.UUID.generate()}/stranded")

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /api/v2/specs/:id/plans" do
    test "returns the plans implementing a spec", %{
      conn: conn,
      user: user,
      brain: brain,
      plaintext: plaintext
    } do
      spec = brain_page(brain_id: brain.id, user_id: user.id, title: "Spec")
      {:ok, spec} = Brain.set_page_kind(spec, :spec, actor: user)

      plan = plan_page(brain, user, "Implementer")
      {:ok, _} = Brain.set_page_spec(plan, spec.id, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/specs/#{spec.id}/plans")
        |> json_response(200)

      ids = Enum.map(response["data"], & &1["id"])
      assert plan.id in ids
    end
  end

  describe "tenancy" do
    test "a stranger cannot deliver another brain's plan (404)", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      plan = done_plan(brain, user)

      stranger = generate(user())
      {_t, stranger_plaintext} = api_token(actor: stranger, scope: :write)

      response =
        conn
        |> auth(stranger_plaintext)
        |> post("/api/v2/plans/#{plan.id}/deliver", %{})

      assert json_response(response, 404)["error"]["code"] == "not_found"
    end

    test "a wrong-workspace token cannot deliver a personal brain's plan (403)", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      plan = done_plan(brain, user)

      ws = generate(workspace(actor: user))
      {_t, other_ws_plaintext} = api_token(actor: user, scope: :write, workspace_id: ws.id)

      response =
        conn
        |> auth(other_ws_plaintext)
        |> post("/api/v2/plans/#{plan.id}/deliver", %{})

      assert json_response(response, 403)["error"]["code"] == "workspace_mismatch"
    end

    test "a read-scope token cannot deliver (403 insufficient_scope)", %{
      conn: conn,
      user: user,
      brain: brain
    } do
      plan = done_plan(brain, user)
      {_t, read_plaintext} = api_token(actor: user, scope: :read)

      response =
        conn
        |> auth(read_plaintext)
        |> post("/api/v2/plans/#{plan.id}/deliver", %{})

      assert json_response(response, 403)["error"]["code"] == "insufficient_scope"
    end
  end
end
