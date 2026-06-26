defmodule Magus.MCP.Auth.StateTest do
  @moduledoc """
  Drives `Magus.MCP.Auth.State.issue/2` + `verify/1` — the HMAC-signed OAuth
  `state` parameter and the server-side PKCE verifier store.

  Exercises the real `Magus.Cache` (supervised in the test env), not a mock, so
  single-use deletion and TTL keying are genuinely covered.

  Required cases:

    * roundtrip: `issue` then `verify` returns the right server_id/user_id/verifier
    * tampered state (a flipped byte) -> `:invalid_state`
    * expired timestamp (past the 10-min window) -> `:expired`
    * missing verifier (cache entry gone) -> `:no_verifier`
    * single-use: a second `verify` of the same state -> `:no_verifier`
  """
  use ExUnit.Case, async: false

  alias Magus.Cache
  alias Magus.MCP.Auth.State

  setup do
    server_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    %{server_id: server_id, user_id: user_id}
  end

  describe "issue/2 + verify/1 roundtrip" do
    test "verify returns the issued server_id, user_id, and verifier", %{
      server_id: server_id,
      user_id: user_id
    } do
      {state, verifier} = State.issue(server_id, user_id)

      assert is_binary(state)
      assert is_binary(verifier)
      # RFC 7636: 43-128 char base64url, unreserved chars only.
      assert String.length(verifier) >= 43
      assert verifier =~ ~r/\A[A-Za-z0-9\-._~]+\z/

      assert {:ok, claims} = State.verify(state)
      assert claims.server_id == server_id
      assert claims.user_id == user_id
      assert claims.verifier == verifier
    end

    test "the verifier is stored in the cache keyed by the state", %{
      server_id: server_id,
      user_id: user_id
    } do
      {state, verifier} = State.issue(server_id, user_id)
      assert Cache.get(state) == verifier
    end

    test "each issue produces a distinct, high-entropy verifier", %{
      server_id: server_id,
      user_id: user_id
    } do
      # NOTE: the `state` is derived from `server_id:user_id:timestamp` and the
      # timestamp has 1-second resolution, so two `issue/2` calls within the same
      # second yield the SAME state string (the second overwrites the first's
      # cache entry — benign for our single-flow-per-state usage). The verifier,
      # however, is freshly random each time and is the security-critical secret.
      {_state1, verifier1} = State.issue(server_id, user_id)
      {_state2, verifier2} = State.issue(server_id, user_id)

      refute verifier1 == verifier2
    end
  end

  describe "verify/1 rejects bad states" do
    test "a tampered state -> :invalid_state", %{server_id: server_id, user_id: user_id} do
      {state, _verifier} = State.issue(server_id, user_id)

      tampered = flip_last_char(state)
      refute tampered == state

      assert {:error, :invalid_state} = State.verify(tampered)
    end

    test "garbage that is not valid base64 -> :invalid_state" do
      assert {:error, :invalid_state} = State.verify("!!!not base64!!!")
    end

    test "an expired state (past the 10-min window) -> :expired", %{
      server_id: server_id,
      user_id: user_id
    } do
      # 11 minutes in the past, beyond the 600s validity window.
      expired_ts = System.system_time(:second) - 660
      state = State.build_signed_state(server_id, user_id, expired_ts)

      assert {:error, :expired} = State.verify(state)
    end

    test ":invalid_state / :expired are rejected before the cache is touched", %{
      server_id: server_id,
      user_id: user_id
    } do
      # An expired but otherwise valid state whose verifier IS present in the
      # cache must NOT evict that entry — error ordering protects the store.
      expired_ts = System.system_time(:second) - 660
      state = State.build_signed_state(server_id, user_id, expired_ts)
      Cache.put(state, "planted-verifier", ttl: 600)

      assert {:error, :expired} = State.verify(state)
      # Still there: the rejection happened before any cache access.
      assert Cache.get(state) == "planted-verifier"

      Cache.delete(state)
    end
  end

  describe "verifier store (single-use)" do
    test "missing verifier -> :no_verifier", %{server_id: server_id, user_id: user_id} do
      {state, _verifier} = State.issue(server_id, user_id)
      # Simulate the verifier expiring / being dropped from the cache.
      Cache.delete(state)

      assert {:error, :no_verifier} = State.verify(state)
    end

    test "a second verify of the same state -> :no_verifier (single-use)", %{
      server_id: server_id,
      user_id: user_id
    } do
      {state, verifier} = State.issue(server_id, user_id)

      assert {:ok, %{verifier: ^verifier}} = State.verify(state)
      # The first verify consumed (deleted) the verifier.
      assert Cache.get(state) == nil
      assert {:error, :no_verifier} = State.verify(state)
    end
  end

  # Flip the final character of the encoded state so the HMAC no longer matches.
  defp flip_last_char(state) do
    {init, last} = String.split_at(state, -1)
    replacement = if last == "A", do: "B", else: "A"
    init <> replacement
  end
end
