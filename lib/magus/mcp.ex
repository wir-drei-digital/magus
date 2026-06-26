defmodule Magus.MCP do
  @moduledoc """
  MCP (Model Context Protocol) integration domain.

  Magus is the MCP *client*: it connects outbound to remote MCP servers that
  users register, discovers their tools, and (in later plans) exposes them to
  the agent. This domain owns server configuration (`Server`) and per-user
  encrypted credentials (`ServerCredential`).
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    # Names are GLOBAL across the generated SPA client, so every rpc_action keeps
    # an `mcp`-prefix to avoid colliding with other domains' actions.
    resource Magus.MCP.Server do
      rpc_action :list_mcp_servers, :read
      rpc_action :create_mcp_server, :create
      rpc_action :update_mcp_server, :update
      rpc_action :toggle_mcp_server, :toggle
      rpc_action :destroy_mcp_server, :destroy

      # Generic action (action type `:action`); takes `mcp_server_id` and loads
      # the server actor-scoped before discovering. rpc-exposable like any action.
      rpc_action :discover_mcp_server, :discover

      # "Get one server" reuses the actor-scoped primary `:read` with a single-id
      # filter — same shape as `get_conversation`/`get_context_window` elsewhere.
      rpc_action :get_mcp_server, :read do
        get_by [:id]
      end
    end

    # Only non-secret fields (`status`, `mcp_server_id`, …) are public?; the
    # encrypted secret attributes (`static_headers`, `oauth_tokens`,
    # `oauth_client`) are public?: false and never serialized onto the read type.
    # The `upsert_static_headers` INPUT type DOES carry a write-only headers map —
    # that is the argument, not a readable field.
    resource Magus.MCP.ServerCredential do
      rpc_action :upsert_mcp_static_headers, :upsert_static_headers
      rpc_action :set_mcp_credential_status, :set_status
      rpc_action :disconnect_mcp_credential, :disconnect

      # Per-user credential for one server; returns a single record (or null).
      rpc_action :get_mcp_credential, :for_server_and_user do
        get_by [:mcp_server_id]
      end
    end
  end

  resources do
    resource Magus.MCP.Server do
      define :create_server, action: :create
      define :update_server, action: :update
      define :get_server, action: :read, get_by: [:id]
      # Every server the actor can read (personal + workspace shares). Backed by
      # the primary `:read`, which is actor-scoped by `workspace_scoped_policies`.
      # The catalog uses this as its single MCP access checkpoint; do NOT swap in
      # `:my_servers` (owned-only) or it would miss workspace shares.
      define :list_accessible_servers, action: :read
      define :list_my_servers, action: :my_servers
      define :list_workspace_servers, action: :workspace_servers, args: [:workspace_id]
      define :set_server_provenance, action: :set_provenance
      define :update_server_cached_tools, action: :update_cached_tools
      define :cache_server_oauth_metadata, action: :cache_oauth_metadata
      define :record_server_reachability, action: :record_reachability
      define :toggle_server, action: :toggle
      define :destroy_server, action: :destroy

      # Generic discovery action for the SPA's Test/Refresh button. Wraps
      # `Magus.MCP.Discovery.discover_and_cache/2` as an Ash action so it can be
      # rpc-exposed (the plain `discover_and_cache/2` defdelegate below cannot).
      # Takes the server id; loads it actor-scoped before discovering.
      define :discover_server, action: :discover, args: [:mcp_server_id]
    end

    resource Magus.MCP.ServerCredential do
      define :upsert_static_headers, action: :upsert_static_headers
      define :store_oauth_client, action: :store_oauth_client
      define :store_oauth_tokens, action: :store_oauth_tokens
      define :refresh_oauth_tokens, action: :refresh_oauth_tokens
      define :set_credential_status, action: :set_status

      define :get_credential_for_server,
        action: :for_server_and_user,
        args: [:mcp_server_id],
        get?: true,
        not_found_error?: false
    end
  end

  @doc """
  Connects to `server`, lists its tools, and returns normalized tool defs
  without persisting anything. See `Magus.MCP.Discovery.test_connection/2`.
  """
  @spec test_connection(Magus.MCP.Server.t(), struct()) :: {:ok, [map()]} | {:error, term()}
  defdelegate test_connection(server, actor), to: Magus.MCP.Discovery

  @doc """
  Connects to `server`, normalizes its tools, caches them on the row, and records
  reachability. See `Magus.MCP.Discovery.discover_and_cache/2`.
  """
  @spec discover_and_cache(Magus.MCP.Server.t(), struct()) ::
          {:ok, Magus.MCP.Server.t()} | {:error, term()}
  defdelegate discover_and_cache(server, actor), to: Magus.MCP.Discovery

  @doc """
  Lists importable remote servers from the public MCP registry.
  See `Magus.MCP.Registry.list/1`.
  """
  defdelegate list_registry_servers(opts \\ []), to: Magus.MCP.Registry, as: :list

  @doc """
  Fetches one registry server by reverse-DNS name. See `Magus.MCP.Registry.get/2`.
  """
  defdelegate get_registry_server(registry_name, version \\ "latest"),
    to: Magus.MCP.Registry,
    as: :get

  @doc """
  Imports a registry server into a `Magus.MCP.Server` for `actor`.
  See `Magus.MCP.Importer.import_from_registry/3`.
  """
  defdelegate import_from_registry(registry_name, opts \\ [], actor),
    to: Magus.MCP.Importer
end
