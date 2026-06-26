defmodule Magus.MCP.Auth.State do
  @moduledoc """
  HMAC-signed OAuth `state` + the server-side PKCE verifier store for the
  per-user MCP OAuth 2.1 browser-redirect flow.

  The browser-redirect flow needs two things the callback can trust:

    * a tamper-proof `state` that binds the flow to a specific
      `{server_id, user_id}` and a timestamp, so the callback can verify the
      request originated from us and is recent; and
    * the PKCE `code_verifier`, which must NOT travel through the browser. We
      keep it server-side, keyed by the opaque `state`, and hand only the S256
      *challenge* (computed downstream by oidcc, not here) to the authorization
      server.

  `state` encodes `server_id:user_id:timestamp:HMAC` (mirrors the integrations
  `oauth_controller`, but additionally binds `server_id`). `server_id`/`user_id`
  are UUIDs and the base64url signature uses only `-`/`_`, so neither carries a
  `:` — the decoded string splits into exactly four parts.

  ## Single-node caveat

  The verifier lives in node-local ETS (`Magus.Cache`). The authorize-start and
  the OAuth callback MUST therefore land on the **same BEAM node** — the verifier
  written by `issue/2` is only visible to a `verify/1` running on that same node.
  This matches the existing integrations OAuth assumption. A multi-node
  deployment would need a shared store (e.g. Redis/Cachex distributed) behind
  this module instead of `Magus.Cache`.
  """

  alias Magus.Cache

  # State (and verifier) are valid for 10 minutes — mirrors `oauth_controller`.
  @validity_seconds 600

  @type claims :: %{server_id: String.t(), user_id: String.t(), verifier: String.t()}

  @doc """
  Issues a fresh HMAC-signed `state` + PKCE `code_verifier` for a flow.

  Generates a high-entropy RFC 7636 verifier, stores it in `Magus.Cache` keyed by
  the `state` (TTL #{@validity_seconds}s, single-use), and returns
  `{state, verifier}`. The caller hands `state` to the authorization server and
  the `verifier` to oidcc (which derives the S256 challenge); the verifier itself
  never leaves the server.
  """
  @spec issue(String.t(), String.t()) :: {String.t(), String.t()}
  def issue(server_id, user_id) when is_binary(server_id) and is_binary(user_id) do
    state = build_signed_state(server_id, user_id, System.system_time(:second))
    verifier = generate_verifier()

    :ok = Cache.put(state, verifier, ttl: @validity_seconds)

    {state, verifier}
  end

  @doc """
  Verifies a `state` and consumes its single-use PKCE verifier.

  Validates the HMAC signature and the 10-minute timestamp window FIRST — a
  tampered or expired `state` is rejected before the cache is ever touched, so it
  can neither probe nor evict stored verifiers. Only a fully-valid state then
  looks up and **deletes** (single-use) the verifier.

    * `{:ok, %{server_id, user_id, verifier}}` — valid + verifier present.
    * `{:error, :invalid_state}` — garbled/tampered state or bad signature.
    * `{:error, :expired}`       — valid signature, but past the validity window.
    * `{:error, :no_verifier}`   — valid state, but the verifier is missing or was
      already consumed.
  """
  @spec verify(String.t()) :: {:ok, claims()} | {:error, :invalid_state | :expired | :no_verifier}
  def verify(state) when is_binary(state) do
    with {:ok, server_id, user_id, timestamp} <- decode_and_authenticate(state),
         :ok <- check_freshness(timestamp) do
      consume_verifier(state, server_id, user_id)
    end
  end

  @doc false
  # Builds the HMAC-signed state for an explicit timestamp. Public only so tests
  # can construct back-dated (expired) states without weakening `issue/2`, which
  # always stamps the current time. NOT part of the supported API.
  @spec build_signed_state(String.t(), String.t(), integer()) :: String.t()
  def build_signed_state(server_id, user_id, timestamp) do
    data = "#{server_id}:#{user_id}:#{timestamp}"
    signature = sign(data)
    Base.url_encode64("#{data}:#{signature}")
  end

  # --- internals ---

  # Decode the opaque state and verify the HMAC. Returns the bound identifiers on
  # success; collapses any structural/signature problem to `:invalid_state`.
  defp decode_and_authenticate(state) do
    with {:ok, decoded} <- Base.url_decode64(state),
         [server_id, user_id, timestamp, signature] <- String.split(decoded, ":"),
         true <- valid_signature?("#{server_id}:#{user_id}:#{timestamp}", signature) do
      {:ok, server_id, user_id, timestamp}
    else
      _ -> {:error, :invalid_state}
    end
  end

  defp check_freshness(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} ->
        if System.system_time(:second) - ts < @validity_seconds do
          :ok
        else
          {:error, :expired}
        end

      _ ->
        # A non-integer timestamp means the state is structurally bogus despite a
        # matching signature shape; treat as tampered rather than merely expired.
        {:error, :invalid_state}
    end
  end

  # Look up + delete (single-use) the stored verifier.
  defp consume_verifier(state, server_id, user_id) do
    case Cache.get(state) do
      nil ->
        {:error, :no_verifier}

      verifier when is_binary(verifier) ->
        :ok = Cache.delete(state)
        {:ok, %{server_id: server_id, user_id: user_id, verifier: verifier}}
    end
  end

  # RFC 7636 §4.1: 32 random bytes base64url-encoded (no padding) yields a 43-char
  # verifier built only from unreserved characters. oidcc derives the S256
  # challenge from this downstream; we never compute or store the challenge here.
  defp generate_verifier do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp sign(data) do
    :crypto.mac(:hmac, :sha256, oauth_secret(), data) |> Base.url_encode64()
  end

  # Constant-time comparison — never `==` on the signature.
  defp valid_signature?(data, signature) do
    Plug.Crypto.secure_compare(sign(data), signature)
  end

  defp oauth_secret do
    Application.get_env(:magus, :oauth_state_secret) ||
      Application.get_env(:magus, MagusWeb.Endpoint)[:secret_key_base]
  end
end
