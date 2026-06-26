defmodule Magus.Accounts.ApiTokenTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Accounts

  describe "create_api_token/2" do
    setup do
      user = generate(user())
      %{user: user}
    end

    test "creates a token with hashed secret and display prefix", %{user: user} do
      {:ok, %{token: token, plaintext: plaintext}} =
        Accounts.create_api_token(
          %{name: "Claude Code on laptop", scope: :write, created_via: :settings},
          actor: user
        )

      assert token.name == "Claude Code on laptop"
      assert token.scope == :write
      assert token.created_via == :settings
      assert token.user_id == user.id
      assert is_nil(token.workspace_id)
      assert is_nil(token.expires_at)
      assert is_nil(token.revoked_at)

      assert String.starts_with?(plaintext, "mgs_pat_")
      assert String.length(plaintext) == 40
      assert token.key_prefix == String.slice(plaintext, 0, 14)

      assert token.key_hash ==
               :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
    end

    test "defaults scope to :read", %{user: user} do
      {:ok, %{token: token}} =
        Accounts.create_api_token(
          %{name: "CI", created_via: :cli_login},
          actor: user
        )

      assert token.scope == :read
    end

    test "accepts an optional expires_at", %{user: user} do
      expires_at = DateTime.utc_now() |> DateTime.add(86_400, :second)

      {:ok, %{token: token}} =
        Accounts.create_api_token(
          %{name: "Day pass", scope: :write, created_via: :settings, expires_at: expires_at},
          actor: user
        )

      assert DateTime.compare(token.expires_at, expires_at) == :eq
    end
  end

  describe "get_api_token_by_hash/2" do
    test "returns the token matching the hash, excluding revoked and expired tokens" do
      user = generate(user())

      {:ok, %{token: token, plaintext: plaintext}} =
        Accounts.create_api_token(
          %{name: "Active", scope: :read, created_via: :settings},
          actor: user
        )

      hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

      {:ok, found} = Accounts.get_api_token_by_hash(hash, authorize?: false)
      assert found.id == token.id

      {:ok, _} = Accounts.revoke_api_token(token, actor: user)
      assert {:error, _} = Accounts.get_api_token_by_hash(hash, authorize?: false)
    end

    test "excludes expired tokens" do
      user = generate(user())
      past = DateTime.utc_now() |> DateTime.add(-3600, :second)

      {:ok, %{plaintext: plaintext}} =
        Accounts.create_api_token(
          %{name: "Stale", scope: :read, created_via: :settings, expires_at: past},
          actor: user
        )

      hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
      assert {:error, _} = Accounts.get_api_token_by_hash(hash, authorize?: false)
    end
  end

  describe "list_api_tokens/0" do
    test "returns only the actor's tokens" do
      user_a = generate(user())
      user_b = generate(user())

      {:ok, _} =
        Accounts.create_api_token(
          %{name: "A", scope: :read, created_via: :settings},
          actor: user_a
        )

      {:ok, _} =
        Accounts.create_api_token(
          %{name: "B", scope: :read, created_via: :settings},
          actor: user_b
        )

      {:ok, tokens} = Accounts.list_api_tokens(actor: user_a)
      assert length(tokens) == 1
      assert hd(tokens).name == "A"
    end
  end

  describe "revoke_api_token/2" do
    test "stamps revoked_at" do
      user = generate(user())

      {:ok, %{token: token}} =
        Accounts.create_api_token(
          %{name: "Old", scope: :read, created_via: :settings},
          actor: user
        )

      {:ok, revoked} = Accounts.revoke_api_token(token, actor: user)
      assert revoked.revoked_at != nil
    end
  end

  describe "sensitive fields" do
    test "key_hash and key_prefix are not exposed via inspect" do
      user = generate(user())

      {:ok, %{token: token}} =
        Magus.Accounts.create_api_token(
          %{name: "Secret", scope: :read, created_via: :settings},
          actor: user
        )

      inspected = inspect(token)
      refute inspected =~ token.key_hash
      refute inspected =~ token.key_prefix
    end
  end
end
