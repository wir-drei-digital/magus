defmodule Magus.MCP.ServerCredential do
  @moduledoc """
  Per-user encrypted credentials for an MCP server. Owner-only: a credential is
  readable and writable only by the user it belongs to (`relates_to_actor_via`),
  so sharing a `Server` never exposes another member's tokens. Secrets are
  encrypted at rest via `Magus.Integrations.Vault`.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.MCP,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "mcp_server_credentials"
    repo Magus.Repo

    references do
      reference :mcp_server, on_delete: :delete
      reference :user, on_delete: :delete
    end
  end

  typescript do
    # The SPA only ever needs to know a server's connection STATUS, never the
    # secret material. The encrypted attributes (`static_headers`,
    # `oauth_tokens`, `oauth_client`) are `public?: false` below, so
    # ash_typescript never serializes them onto this type. The
    # `upsert_static_headers` write action's `static_headers` argument is
    # write-only input and is safe to expose.
    type_name "MCPServerCredential"
  end

  actions do
    read :read do
      primary? true
    end

    read :for_server_and_user do
      argument :mcp_server_id, :uuid, allow_nil?: false
      filter expr(mcp_server_id == ^arg(:mcp_server_id) and user_id == ^actor(:id))
    end

    create :upsert_static_headers do
      accept [:mcp_server_id]

      # Take the headers as a plain `:map` ARGUMENT rather than accepting the
      # `static_headers` attribute directly. The attribute's `EncryptedMap` type
      # is not representable by ash_typescript (it would crash codegen), so the
      # rpc input type carries this mappable `:map` instead. The change below
      # writes it onto the encrypted attribute, which still encrypts at rest.
      argument :static_headers, :map, allow_nil?: false

      upsert? true
      upsert_identity :unique_server_user
      upsert_fields [:static_headers, :auth_kind, :status]
      change relate_actor(:user)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :static_headers,
          Ash.Changeset.get_argument(changeset, :static_headers)
        )
      end

      change set_attribute(:auth_kind, :static_header)
      change set_attribute(:status, :connected)
    end

    create :store_oauth_tokens do
      accept [:mcp_server_id, :oauth_tokens, :oauth_expires_at, :oauth_client]
      upsert? true
      upsert_identity :unique_server_user
      upsert_fields [:oauth_tokens, :oauth_expires_at, :oauth_client, :auth_kind, :status]
      change relate_actor(:user)
      change set_attribute(:auth_kind, :oauth)
      change set_attribute(:status, :connected)
    end

    # Persist ONLY the OAuth client identity (client_id/secret from DCR or manual
    # config) before any tokens exist. The authorize-start flow registers a
    # client, stores it here, then the callback's token exchange reuses the SAME
    # client_id. Deliberately does NOT set status :connected — there are no
    # tokens yet, so a new row keeps the default :disconnected. The
    # relate_actor/set_attribute changes force the non-atomic changeset path, so
    # the `oauth_client` EncryptedMap is encrypted at rest (the atomic SQL path
    # would skip `dump_to_native`). Server-side only — not rpc-exposed.
    create :store_oauth_client do
      accept [:mcp_server_id, :oauth_client]
      upsert? true
      upsert_identity :unique_server_user
      upsert_fields [:oauth_client, :auth_kind]
      change relate_actor(:user)
      change set_attribute(:auth_kind, :oauth)
    end

    update :refresh_oauth_tokens do
      # EncryptedMap encrypts in `dump_to_native`, which the atomic-update SQL
      # path bypasses (it would cast the map straight to jsonb against a bytea
      # column). Force the non-atomic changeset path so the value is encrypted.
      require_atomic? false
      accept [:oauth_tokens, :oauth_expires_at]
    end

    update :set_status do
      accept [:status]
    end

    # Disconnect the current user from this server: clear the OAuth tokens and
    # expiry and flip status to :disconnected. Deliberately KEEPS `oauth_client`
    # so a later reconnect reuses the same DCR-registered client (no re-register).
    # require_atomic? false mirrors the other credential updates: the EncryptedMap
    # attribute must go through the non-atomic changeset path (the atomic SQL path
    # would skip `dump_to_native`).
    update :disconnect do
      require_atomic? false
      accept []
      change set_attribute(:oauth_tokens, nil)
      change set_attribute(:oauth_expires_at, nil)
      change set_attribute(:status, :disconnected)
    end

    destroy :destroy do
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if Magus.MCP.ServerCredential.Checks.ServerAccessibleToActor
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :auth_kind, :atom do
      allow_nil? false
      public? true
      default :static_header
      constraints one_of: [:static_header, :oauth]
    end

    # Encrypted secret material — MUST stay `public?: false` so ash_typescript
    # never serializes it onto the `MCPServerCredential` type. The SPA only
    # reads `status`; secrets live server-side and are written via the
    # action arguments (write-only input), never read back over the wire.
    attribute :static_headers, Magus.Integrations.EncryptedMap do
      allow_nil? true
      public? false
      sensitive? true
      description "Per-user static headers (bearer / API key), decrypted on load."
    end

    attribute :oauth_tokens, Magus.Integrations.EncryptedMap do
      allow_nil? true
      public? false
      sensitive? true
      description "Per-user OAuth access/refresh tokens, decrypted on load."
    end

    attribute :oauth_expires_at, :utc_datetime_usec, public?: true, allow_nil?: true

    attribute :oauth_client, Magus.Integrations.EncryptedMap do
      allow_nil? true
      public? false
      sensitive? true
      description "Per-user OAuth client_id/secret (from DCR or manual config)."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :disconnected
      constraints one_of: [:disconnected, :needs_auth, :connected, :error]
    end

    timestamps()
  end

  relationships do
    belongs_to :mcp_server, Magus.MCP.Server do
      public? true
      allow_nil? false
    end

    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end
  end

  identities do
    identity :unique_server_user, [:mcp_server_id, :user_id]
  end
end
