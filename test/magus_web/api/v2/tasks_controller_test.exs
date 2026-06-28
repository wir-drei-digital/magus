defmodule MagusWeb.Api.V2.TasksControllerTest do
  @moduledoc """
  Covers the `/api/v2` plan-task surface: index/create/show/update (Task 7),
  claim/release with 409-on-contention (Task 8), and dependency add/remove
  (Task 9). Tenancy is enforced by `RequireWorkspaceMatch` (token workspace vs
  the task's brain workspace) plus the Ash brain-access policy.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Plan

  setup do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, plaintext: plaintext, brain: brain, page: page}
  end

  defp auth(conn, plaintext), do: put_req_header(conn, "authorization", "Bearer #{plaintext}")

  describe "GET /api/v2/plans/:plan_id/tasks" do
    test "lists a plan's tasks", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, _} = Plan.create_plan_task(page.id, %{title: "First"}, actor: user)
      {:ok, _} = Plan.create_plan_task(page.id, %{title: "Second"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/plans/#{page.id}/tasks")
        |> json_response(200)

      titles = Enum.map(response["data"], & &1["title"])
      assert "First" in titles
      assert "Second" in titles
      assert Enum.all?(response["data"], &(&1["brain_page_id"] == page.id))
    end

    test "?ready=true returns only ready tasks", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, ready} = Plan.create_plan_task(page.id, %{title: "Ready"}, actor: user)
      {:ok, claimed} = Plan.create_plan_task(page.id, %{title: "Claimed"}, actor: user)
      {:ok, _} = Plan.claim_task(claimed, %{assigned_to_agent: "agent-1"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/plans/#{page.id}/tasks?ready=true")
        |> json_response(200)

      ids = Enum.map(response["data"], & &1["id"])
      assert ready.id in ids
      refute claimed.id in ids
    end
  end

  describe "POST /api/v2/plans/:plan_id/tasks" do
    test "creates a task (201)", %{conn: conn, page: page, plaintext: plaintext} do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{page.id}/tasks", %{"title" => "New task", "priority" => "high"})
        |> json_response(201)

      assert response["data"]["title"] == "New task"
      assert response["data"]["priority"] == "high"
      assert response["data"]["status"] == "open"
      assert response["data"]["brain_page_id"] == page.id
    end

    test "422 on invalid input (missing title)", %{conn: conn, page: page, plaintext: plaintext} do
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{page.id}/tasks", %{"priority" => "high"})

      assert json_response(response, 422)["error"]["code"] == "validation_error"
    end

    test "read-scope token gets 403 on POST", %{conn: conn, user: user, page: page} do
      {_t, read_plaintext} = api_token(actor: user, scope: :read)

      response =
        conn
        |> auth(read_plaintext)
        |> post("/api/v2/plans/#{page.id}/tasks", %{"title" => "Nope"})

      assert json_response(response, 403)["error"]["code"] == "insufficient_scope"
    end
  end

  describe "GET /api/v2/tasks/:id" do
    test "returns the task by id", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Findable"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> get("/api/v2/tasks/#{task.id}")
        |> json_response(200)

      assert response["data"]["id"] == task.id
      assert response["data"]["title"] == "Findable"
    end

    test "404 for unknown id", %{conn: conn, plaintext: plaintext} do
      response = conn |> auth(plaintext) |> get("/api/v2/tasks/#{Ecto.UUID.generate()}")
      assert json_response(response, 404)["error"]["code"] == "not_found"
    end
  end

  describe "PATCH /api/v2/tasks/:id" do
    test "updates status", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Update me"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> patch("/api/v2/tasks/#{task.id}", %{"status" => "done"})
        |> json_response(200)

      assert response["data"]["status"] == "done"
    end

    test "422 on invalid status", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Update me"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> patch("/api/v2/tasks/#{task.id}", %{"status" => "not-a-status"})

      assert json_response(response, 422)["error"]["code"] == "validation_error"
    end

    test "advisory: a mismatched `as` gets 409 not_claimant", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Guarded"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude@A"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> patch("/api/v2/tasks/#{task.id}", %{"as" => "claude@B", "status" => "done"})

      assert json_response(response, 409)["error"]["code"] == "not_claimant"
    end

    test "advisory: no `as` allows the human-override update (200)", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Override"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude@A"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> patch("/api/v2/tasks/#{task.id}", %{"status" => "done"})
        |> json_response(200)

      assert response["data"]["status"] == "done"
    end
  end

  describe "POST /api/v2/tasks/:id/claim" do
    test "claims with {as} -> 200 in_progress", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Claimable"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/claim", %{"as" => "claude-code"})
        |> json_response(200)

      assert response["data"]["status"] == "in_progress"
      assert response["data"]["assigned_to_agent"] == "claude-code"
    end

    test "claims for the user when no `as` given", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Claimable"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/claim", %{})
        |> json_response(200)

      assert response["data"]["status"] == "in_progress"
      assert response["data"]["assigned_to_user_id"] == user.id
    end

    test "second claim returns 409 already_claimed", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Contended"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "agent-1"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/claim", %{"as" => "agent-2"})

      assert json_response(response, 409)["error"]["code"] == "already_claimed"
    end

    test "trims a padded `as` label before storing it as assigned_to_agent", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Trim me"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/claim", %{"as" => "  claude-code@sess  "})
        |> json_response(200)

      assert response["data"]["assigned_to_agent"] == "claude-code@sess"
    end
  end

  describe "POST /api/v2/tasks/:id/release" do
    test "releases a claimed task back to open", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Releasable"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "agent-1"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/release", %{})
        |> json_response(200)

      assert response["data"]["status"] == "open"
      assert response["data"]["assigned_to_agent"] == nil
    end

    test "advisory: a mismatched `as` gets 409 not_claimant", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Guarded"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude@A"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/release", %{"as" => "claude@B"})

      assert json_response(response, 409)["error"]["code"] == "not_claimant"
    end

    test "advisory: a matching `as` releases (200)", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Matching"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude@A"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/release", %{"as" => "claude@A"})
        |> json_response(200)

      assert response["data"]["status"] == "open"
    end

    test "advisory: no `as` allows the human-override release (200)", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Override"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude@A"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/release", %{})
        |> json_response(200)

      assert response["data"]["status"] == "open"
    end
  end

  describe "POST/DELETE /api/v2/tasks/:id/dependencies" do
    test "adds a dependency (201)", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Dependent"}, actor: user)
      {:ok, other} = Plan.create_plan_task(page.id, %{title: "Blocker"}, actor: user)

      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/dependencies", %{"depends_on_id" => other.id})
        |> json_response(201)

      assert response["data"]["task_id"] == task.id
      assert response["data"]["depends_on_id"] == other.id
    end

    test "422 on a cycle", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, a} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
      {:ok, b} = Plan.create_plan_task(page.id, %{title: "B"}, actor: user)
      {:ok, _} = Plan.add_task_dependency(a.id, b.id, actor: user)

      # b depends on a would close the cycle a -> b -> a.
      response =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{b.id}/dependencies", %{"depends_on_id" => a.id})

      assert json_response(response, 422)["error"]["code"] == "validation_error"
    end

    test "removes a dependency", %{conn: conn, user: user, page: page, plaintext: plaintext} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Dependent"}, actor: user)
      {:ok, other} = Plan.create_plan_task(page.id, %{title: "Blocker"}, actor: user)
      {:ok, dep} = Plan.add_task_dependency(task.id, other.id, actor: user)

      conn =
        conn
        |> auth(plaintext)
        |> delete("/api/v2/tasks/#{task.id}/dependencies/#{dep.id}")

      assert conn.status in [200, 204]
      assert {:ok, []} = Plan.dependencies_of(task.id, actor: user)
    end
  end

  describe "tenancy: stranger / wrong workspace" do
    test "a stranger cannot access another brain's task", %{
      conn: conn,
      user: user,
      page: page
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Private"}, actor: user)

      stranger = generate(user())
      {_t, stranger_plaintext} = api_token(actor: stranger, scope: :write)

      # show -> 404 (Ash policy filters / not found)
      show = conn |> auth(stranger_plaintext) |> get("/api/v2/tasks/#{task.id}")
      assert json_response(show, 404)["error"]["code"] == "not_found"

      # index over the plan -> 404 (page not accessible)
      index = conn |> auth(stranger_plaintext) |> get("/api/v2/plans/#{page.id}/tasks")
      assert json_response(index, 404)["error"]["code"] == "not_found"
    end

    test "a wrong-workspace token cannot access a personal brain's task", %{
      conn: conn,
      user: user,
      page: page
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Personal"}, actor: user)

      ws = generate(workspace(actor: user))
      {_t, other_ws_plaintext} = api_token(actor: user, scope: :write, workspace_id: ws.id)

      # The brain is personal (workspace_id == nil); a workspace-scoped token
      # mismatches -> 403 workspace_mismatch.
      show = conn |> auth(other_ws_plaintext) |> get("/api/v2/tasks/#{task.id}")
      assert json_response(show, 403)["error"]["code"] == "workspace_mismatch"

      index = conn |> auth(other_ws_plaintext) |> get("/api/v2/plans/#{page.id}/tasks")
      assert json_response(index, 403)["error"]["code"] == "workspace_mismatch"
    end
  end

  describe "POST /api/v2/tasks/:id/heartbeat" do
    test "the claimant renews the lease and gets lease_expires_at back", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Job"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude-code@A"}, actor: user)

      resp =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/heartbeat", %{"as" => "claude-code@A"})
        |> json_response(200)

      assert resp["data"]["lease_expires_at"]
    end

    test "a different label gets 409 not_claimant", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Job"}, actor: user)
      {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude-code@A"}, actor: user)

      resp =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/heartbeat", %{"as" => "claude-code@B"})
        |> json_response(409)

      assert resp["error"]["code"] == "not_claimant"
    end
  end

  describe "claim returns the lease" do
    test "POST claim includes lease_expires_at", %{
      conn: conn,
      user: user,
      page: page,
      plaintext: plaintext
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Grab"}, actor: user)

      resp =
        conn
        |> auth(plaintext)
        |> post("/api/v2/tasks/#{task.id}/claim", %{"as" => "claude-code@A"})
        |> json_response(200)

      assert resp["data"]["lease_expires_at"]
      assert resp["data"]["assigned_to_agent"] == "claude-code@A"
    end
  end

  describe "create sets created_by_label from --as" do
    test "POST create stores the sanitized as label as created_by_label", %{
      conn: conn,
      page: page,
      plaintext: plaintext
    } do
      resp =
        conn
        |> auth(plaintext)
        |> post("/api/v2/plans/#{page.id}/tasks", %{
          "title" => "New",
          "as" => "  claude-code@sess  "
        })
        |> json_response(201)

      assert resp["data"]["created_by_label"] == "claude-code@sess"
    end
  end
end
