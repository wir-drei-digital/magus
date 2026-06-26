defmodule MagusWeb.Api.Plugs.RequireWorkspaceMatchTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch

  setup do
    user = generate(user())
    %{user: user}
  end

  test "passes when token has nil workspace and resource has nil workspace", %{user: user} do
    {token, _} = api_token(actor: user, scope: :write)

    conn =
      build_conn()
      |> assign(:current_token, token)
      |> RequireWorkspaceMatch.check(nil)

    assert {:ok, _conn} = conn
  end

  test "passes when token workspace matches resource workspace", %{user: user} do
    workspace = generate(workspace(actor: user))
    {token, _} = api_token(actor: user, scope: :write, workspace_id: workspace.id)

    conn =
      build_conn()
      |> assign(:current_token, token)
      |> RequireWorkspaceMatch.check(workspace.id)

    assert {:ok, _conn} = conn
  end

  test "rejects 403 when token has workspace but resource has nil workspace", %{user: user} do
    workspace = generate(workspace(actor: user))
    {token, _} = api_token(actor: user, scope: :write, workspace_id: workspace.id)

    {:error, conn} =
      build_conn()
      |> assign(:current_token, token)
      |> RequireWorkspaceMatch.check(nil)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "workspace_mismatch"
  end

  test "rejects 403 when resource is in a different workspace", %{user: user} do
    workspace_a = generate(workspace(actor: user))
    workspace_b = generate(workspace(actor: user))
    {token, _} = api_token(actor: user, scope: :write, workspace_id: workspace_a.id)

    {:error, conn} =
      build_conn()
      |> assign(:current_token, token)
      |> RequireWorkspaceMatch.check(workspace_b.id)

    assert conn.status == 403
  end
end
