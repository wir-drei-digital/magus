defmodule Magus.MCP.Auth.OidccSpikeTest do
  @moduledoc """
  Task-0 API spike (MCP Phase 4 / OAuth 2.1).

  Proves — with NO network — that the installed `oidcc` (3.7.2) gives us the
  exact API surface the rest of Phase 4 depends on:

    * an ad-hoc, worker-free path to build an authorize URL
      (`Oidcc.ProviderConfiguration` struct -> `Oidcc.ClientContext.from_manual/5`
       -> `Oidcc.Authorization.create_redirect_url/2`)
    * PKCE S256 via the `:pkce_verifier` opt (library computes the challenge)
    * the RFC 8707 `resource` param injected through `:url_extension`
      (a list of `{binary, binary}` tuples).

  The pinned findings live in `docs/superpowers/notes/oidcc-api-notes.md`.
  See that doc before building Tasks 1-7 on top of this.
  """
  use ExUnit.Case, async: true

  # Fake, hand-built issuer config — never touches the network. Only the fields
  # the authorize path reads are populated; everything else takes record
  # defaults. `code_challenge_methods_supported` MUST advertise "S256" or oidcc
  # silently falls back to `plain` (or omits PKCE entirely).
  defp fake_provider_configuration do
    %Oidcc.ProviderConfiguration{
      issuer: "https://issuer.example.com",
      authorization_endpoint: "https://issuer.example.com/authorize",
      token_endpoint: "https://issuer.example.com/token",
      jwks_uri: "https://issuer.example.com/jwks",
      scopes_supported: ["openid"],
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      subject_types_supported: [:public],
      id_token_signing_alg_values_supported: ["RS256"],
      token_endpoint_auth_methods_supported: ["client_secret_basic"],
      code_challenge_methods_supported: ["S256"],
      # booleans the record requires non-nil
      claims_parameter_supported: false,
      request_parameter_supported: false,
      request_uri_parameter_supported: false,
      require_request_uri_registration: false,
      require_pushed_authorization_requests: false,
      authorization_response_iss_parameter_supported: false,
      require_signed_request_object: false,
      tls_client_certificate_bound_access_tokens: false,
      claim_types_supported: [:normal],
      revocation_endpoint_auth_methods_supported: ["client_secret_basic"],
      introspection_endpoint_auth_methods_supported: ["client_secret_basic"],
      mtls_endpoint_aliases: %{},
      extra_fields: %{}
    }
  end

  # OAuth-only servers have no JWKS we care about for the authorize step; an
  # empty key set is enough because `from_manual/5` only pattern-matches on a
  # `%JOSE.JWK{}` struct and the authorize URL never touches the keys.
  defp empty_jwks, do: JOSE.JWK.from(%{"keys" => []})

  # RFC 7636 S256: verifier is 43-128 chars of unreserved base64url; the
  # library derives the challenge itself, so we only need to hand it a verifier.
  defp generate_pkce_verifier do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  test "ad-hoc authorize URL carries PKCE S256, state, and the RFC 8707 resource param" do
    pkce_verifier = generate_pkce_verifier()
    state = "hmac-bound-state-token"
    resource = "https://mcp.example.com/server-123"

    client_context =
      Oidcc.ClientContext.from_manual(
        fake_provider_configuration(),
        empty_jwks(),
        "client-abc",
        :unauthenticated
      )

    assert {:ok, redirect} =
             Oidcc.Authorization.create_redirect_url(client_context, %{
               redirect_uri: "https://magus.example.com/oauth/mcp/server-123/callback",
               scopes: ["openid"],
               state: state,
               pkce_verifier: pkce_verifier,
               # RFC 8707 resource indicator, audience-binds the token to the MCP server.
               url_extension: [{"resource", resource}]
             })

    # oidcc returns the URL as an iolist; flatten to a binary to inspect.
    url = IO.iodata_to_binary(redirect)
    %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)

    # PKCE: library-computed S256 challenge, NOT the raw verifier.
    expected_challenge =
      :sha256
      |> :crypto.hash(pkce_verifier)
      |> Base.url_encode64(padding: false)

    assert params["code_challenge_method"] == "S256"
    assert params["code_challenge"] == expected_challenge
    refute params["code_challenge"] == pkce_verifier

    # State + resource round-trip into the URL.
    assert params["state"] == state
    assert params["resource"] == resource

    # Sanity: standard authorize params present.
    assert params["response_type"] == "code"
    assert params["client_id"] == "client-abc"
    assert params["redirect_uri"] == "https://magus.example.com/oauth/mcp/server-123/callback"
    assert String.starts_with?(url, "https://issuer.example.com/authorize?")
  end
end
