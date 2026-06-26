defmodule Magus.MCP.ServerCredentialTest do
  use Magus.ResourceCase, async: true

  alias Magus.MCP

  setup do
    user = generate(user())
    server = generate(mcp_server(actor: user, auth_type: :static_header))
    %{user: user, server: server}
  end

  test "stores and decrypts static headers for the owner", %{user: user, server: server} do
    {:ok, cred} =
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"Authorization" => "Bearer secret"}},
        actor: user
      )

    assert cred.user_id == user.id
    assert cred.auth_kind == :static_header

    {:ok, reloaded} = MCP.get_credential_for_server(server.id, actor: user)
    assert reloaded.static_headers == %{"Authorization" => "Bearer secret"}
  end

  test "another user cannot read the owner's credential", %{user: user, server: server} do
    {:ok, _} =
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"x-api-key" => "k"}},
        actor: user
      )

    other = generate(user())
    assert {:ok, nil} = MCP.get_credential_for_server(server.id, actor: other)
  end

  test "cannot create a credential for a server the actor cannot access", %{server: server} do
    stranger = generate(user())

    assert_forbidden(fn ->
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"x" => "y"}},
        actor: stranger
      )
    end)
  end

  test "encrypts at rest (raw column is not plaintext)", %{user: user, server: server} do
    {:ok, cred} =
      MCP.upsert_static_headers(
        %{
          mcp_server_id: server.id,
          static_headers: %{"Authorization" => "Bearer plaintext_marker"}
        },
        actor: user
      )

    [%{static_headers: raw}] =
      Ecto.Adapters.SQL.query!(
        Magus.Repo,
        "SELECT static_headers FROM mcp_server_credentials WHERE id = $1",
        [Ecto.UUID.dump!(cred.id)]
      ).rows
      |> Enum.map(fn [bin] -> %{static_headers: bin} end)

    refute raw =~ "plaintext_marker"
  end

  test "stores, refreshes, and reloads OAuth tokens for the owner", %{
    user: user,
    server: server
  } do
    {:ok, cred} =
      MCP.store_oauth_tokens(
        %{
          mcp_server_id: server.id,
          oauth_tokens: %{"access_token" => "at1", "refresh_token" => "rt1"},
          oauth_expires_at: DateTime.utc_now(),
          oauth_client: %{"client_id" => "cid"}
        },
        actor: user
      )

    assert cred.auth_kind == :oauth
    assert cred.status == :connected

    # refresh_oauth_tokens writes the encrypted oauth_tokens column; this would
    # fail with a bytea/jsonb datatype_mismatch under an atomic update.
    {:ok, refreshed} =
      MCP.refresh_oauth_tokens(
        cred,
        %{oauth_tokens: %{"access_token" => "at2"}, oauth_expires_at: DateTime.utc_now()},
        actor: user
      )

    {:ok, reloaded} = MCP.get_credential_for_server(server.id, actor: user)
    assert reloaded.id == refreshed.id
    assert reloaded.oauth_tokens == %{"access_token" => "at2"}
  end

  test "store_oauth_tokens upserts the actor's own row, not another user's", %{
    user: user,
    server: server
  } do
    {:ok, first} =
      MCP.store_oauth_tokens(
        %{mcp_server_id: server.id, oauth_tokens: %{"access_token" => "a"}},
        actor: user
      )

    {:ok, second} =
      MCP.store_oauth_tokens(
        %{mcp_server_id: server.id, oauth_tokens: %{"access_token" => "b"}},
        actor: user
      )

    assert second.id == first.id
    assert second.oauth_tokens == %{"access_token" => "b"}
  end

  test "another user cannot update or destroy the owner's credential", %{
    user: user,
    server: server
  } do
    {:ok, cred} =
      MCP.upsert_static_headers(
        %{mcp_server_id: server.id, static_headers: %{"x" => "y"}},
        actor: user
      )

    other = generate(user())

    assert_forbidden(fn ->
      MCP.set_credential_status(cred, %{status: :error}, actor: other)
    end)

    assert_forbidden(fn ->
      MCP.refresh_oauth_tokens(cred, %{oauth_tokens: %{}}, actor: other)
    end)
  end
end
