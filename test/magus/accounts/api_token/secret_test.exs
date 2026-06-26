defmodule Magus.Accounts.ApiToken.SecretTest do
  use ExUnit.Case, async: true

  alias Magus.Accounts.ApiToken.Secret

  describe "generate/0" do
    test "returns a string starting with mgs_pat_ and 32 base62 chars" do
      token = Secret.generate()
      assert String.starts_with?(token, "mgs_pat_")
      assert String.length(token) == String.length("mgs_pat_") + 32

      "mgs_pat_" <> random = token
      assert Regex.match?(~r/^[A-Za-z0-9]{32}$/, random)
    end

    test "two calls return different tokens" do
      refute Secret.generate() == Secret.generate()
    end
  end

  describe "hash/1" do
    test "returns 64-char lowercase hex SHA-256" do
      hash = Secret.hash("mgs_pat_test")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
    end

    test "is deterministic" do
      assert Secret.hash("mgs_pat_test") == Secret.hash("mgs_pat_test")
    end

    test "differs across inputs" do
      refute Secret.hash("a") == Secret.hash("b")
    end
  end

  describe "prefix/1" do
    test "returns the first 14 characters" do
      assert Secret.prefix("mgs_pat_abc123def456ghi") == "mgs_pat_abc123"
      assert String.length(Secret.prefix(Secret.generate())) == 14
    end
  end
end
