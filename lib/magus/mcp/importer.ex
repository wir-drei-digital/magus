defmodule Magus.MCP.Importer do
  @moduledoc """
  One-click import of an MCP server from the registry into a `Magus.MCP.Server`.

  Maps a `%Magus.MCP.RegistryEntry{}` to a server row: splits the registry's full
  endpoint URL into `url` (origin) + `mcp_path`, maps the transport, generates a
  unique handle in the actor's scope, infers the auth type, then creates the
  server (reusing the existing `:create` action and its SSRF validation) and runs
  discovery for no-auth servers. Servers needing credentials are created but left
  for the UI to collect auth (static headers or OAuth) before discovery.

  Idempotent: re-importing a server already present in the same scope returns the
  existing row instead of failing the unique-handle identity.
  """

  require Logger

  alias Magus.MCP
  alias Magus.MCP.{Registry, RegistryEntry, Server}

  @type result :: %{
          server: Server.t(),
          status: :connected | :needs_auth | :error,
          already_imported: boolean(),
          required_headers: [map()]
        }

  @doc """
  Imports the registry server `registry_name` (optionally a specific `:version`,
  `:workspace_id`) on behalf of `actor`.
  """
  @spec import_from_registry(String.t(), keyword(), struct()) ::
          {:ok, result()} | {:error, term()}
  def import_from_registry(registry_name, opts \\ [], actor) when is_binary(registry_name) do
    version = opts[:version] || "latest"

    with {:ok, entry} <- Registry.get(registry_name, version) do
      import_entry(entry, opts, actor)
    end
  end

  @doc """
  Imports an already-resolved `%RegistryEntry{}` (the network-free core of
  `import_from_registry/3`).
  """
  @spec import_entry(RegistryEntry.t(), keyword(), struct()) :: {:ok, result()} | {:error, term()}
  def import_entry(%RegistryEntry{} = entry, opts \\ [], actor) do
    workspace_id = opts[:workspace_id]

    with {:ok, existing} <- find_existing(entry, workspace_id, actor) do
      case existing do
        %Server{} = server ->
          {:ok,
           %{
             server: server,
             status: status_for(server),
             already_imported: true,
             required_headers: []
           }}

        nil ->
          create_and_discover(entry, workspace_id, actor)
      end
    end
  end

  defp create_and_discover(%RegistryEntry{} = entry, workspace_id, actor) do
    {url, mcp_path} = split_url(entry.endpoint_url)

    with {:ok, handle} <- unique_handle(entry.display_name, workspace_id, actor),
         attrs = %{
           name: entry.display_name,
           handle: handle,
           url: url,
           mcp_path: mcp_path,
           transport: entry.transport,
           auth_type: entry.auth_type,
           workspace_id: workspace_id
         },
         {:ok, server} <- MCP.create_server(attrs, actor: actor),
         {:ok, server} <- record_provenance(server, entry, actor) do
      finalize(server, entry, actor)
    end
  end

  defp record_provenance(server, %RegistryEntry{} = entry, actor) do
    MCP.set_server_provenance(
      server,
      %{
        source: :registry,
        registry_name: entry.registry_name,
        registry_version: entry.version,
        description: entry.description,
        repository_url: entry.repository_url
      },
      actor: actor
    )
  end

  # No-auth servers connect immediately; auth-requiring servers wait for the UI
  # to supply credentials (static headers or OAuth) before discovery.
  defp finalize(%Server{auth_type: :none} = server, _entry, actor) do
    case MCP.discover_and_cache(server, actor) do
      {:ok, discovered} ->
        {:ok,
         %{server: discovered, status: :connected, already_imported: false, required_headers: []}}

      {:error, _reason} ->
        # Server is persisted; surface a retryable error state rather than failing
        # the whole import (the row + URL are correct, the remote was just unreachable).
        {:ok, %{server: server, status: :error, already_imported: false, required_headers: []}}
    end
  end

  defp finalize(%Server{} = server, %RegistryEntry{} = entry, _actor) do
    {:ok,
     %{
       server: server,
       status: :needs_auth,
       already_imported: false,
       required_headers: Enum.filter(entry.required_headers, & &1.required)
     }}
  end

  # ── Idempotency ──────────────────────────────────────────────────────────────

  defp find_existing(%RegistryEntry{registry_name: name}, workspace_id, actor) do
    case MCP.list_accessible_servers(actor: actor) do
      {:ok, servers} ->
        match =
          Enum.find(servers, fn s ->
            s.registry_name == name and s.workspace_id == workspace_id
          end)

        {:ok, match}

      {:error, _} = err ->
        err
    end
  end

  defp status_for(%Server{reachability: :ok}), do: :connected
  defp status_for(%Server{reachability: :error}), do: :error
  defp status_for(%Server{}), do: :needs_auth

  # ── URL splitting ────────────────────────────────────────────────────────────

  # The registry gives a full endpoint URL; `ClientManager` dials with
  # `base_url` + `mcp_path`, so split to avoid doubling the path.
  @doc false
  @spec split_url(String.t()) :: {String.t(), String.t()}
  def split_url(endpoint_url) do
    uri = URI.parse(endpoint_url)
    path = uri.path || ""
    path = if uri.query, do: path <> "?" <> uri.query, else: path
    {origin(uri), path}
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    default = if scheme == "https", do: 443, else: 80

    if port && port != default do
      "#{scheme}://#{host}:#{port}"
    else
      "#{scheme}://#{host}"
    end
  end

  # ── Handle generation ────────────────────────────────────────────────────────

  @handle_max 24

  @doc false
  @spec unique_handle(String.t(), Ecto.UUID.t() | nil, struct()) ::
          {:ok, String.t()} | {:error, term()}
  def unique_handle(display_name, workspace_id, actor) do
    base = slugify(display_name)

    case MCP.list_accessible_servers(actor: actor) do
      {:ok, servers} ->
        taken =
          servers
          |> Enum.filter(&(&1.workspace_id == workspace_id))
          |> MapSet.new(& &1.handle)

        {:ok, disambiguate(base, taken)}

      {:error, _} = err ->
        err
    end
  end

  # Coin a handle matching `^[a-z][a-z0-9_]{0,23}$` (the Server.handle constraint).
  defp slugify(name) do
    slug =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> ensure_leading_letter()
      |> String.slice(0, @handle_max)
      |> String.trim("_")

    if slug == "", do: "mcp_server", else: slug
  end

  defp ensure_leading_letter(<<c, _::binary>> = slug) when c in ?a..?z, do: slug
  defp ensure_leading_letter(slug), do: "m_" <> slug

  defp disambiguate(base, taken) do
    if MapSet.member?(taken, base) do
      Enum.find_value(2..99, base, fn n ->
        suffix = "_#{n}"
        candidate = String.slice(base, 0, @handle_max - String.length(suffix)) <> suffix
        if MapSet.member?(taken, candidate), do: nil, else: candidate
      end)
    else
      base
    end
  end
end
