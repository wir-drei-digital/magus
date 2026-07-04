defmodule Magus.Knowledge.Connect do
  @moduledoc """
  Shared "connect a new knowledge source" logic for the SPA wizard.

  Validates credentials through the provider `Connector`, then creates and
  activates a `KnowledgeSource`. Used by both the `KnowledgeSource` generic RPC
  actions (API-key / URL providers, where the SPA supplies the credentials) and
  the OAuth finalize endpoint (which reads the tokens the callback stashed in the
  session, so OAuth secrets never reach the browser).
  """
  alias Magus.Knowledge
  alias Magus.Knowledge.Connector

  # The providers the connect wizard supports (a subset of the source provider
  # enum — the others have no Connector implementation).
  @providers ~w(google_drive notion nextcloud affine web)

  @doc "Provider keys the connect wizard supports."
  def providers, do: @providers

  @doc """
  Validate `auth_config` via the provider connector, then create and activate a
  source owned by `actor`.

  Options: `:actor` (required), `:name`, `:workspace_id`.
  Returns `{:ok, source}` or `{:error, message}`.
  """
  def connect_and_create(provider, auth_config, opts)
      when is_binary(provider) and is_map(auth_config) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, provider_atom} <- parse_provider(provider),
         module <- Connector.connector_for(provider_atom),
         {:ok, _conn} <- module.connect(auth_config),
         attrs = %{
           name: presence(opts[:name]) || default_name(provider_atom),
           provider: provider_atom,
           auth_config: auth_config,
           workspace_id: opts[:workspace_id]
         },
         {:ok, source} <- Knowledge.create_source(attrs, actor: actor),
         {:ok, source} <- Knowledge.update_source_status(source, %{status: :active}, actor: actor) do
      {:ok, source}
    else
      :error -> {:error, "Unknown provider"}
      {:error, reason} -> {:error, friendly_error(reason)}
    end
  end

  @doc """
  Reconnect flow: if the actor already has a source for this provider, validate
  the new credentials and update it in place (clearing any reauth flag and
  reactivating it). Otherwise behaves like `connect_and_create/3`. This is what
  the OAuth finalize endpoint uses so re-authorizing an expired connection heals
  the existing source and its collections instead of stranding them behind a
  duplicate.
  """
  def reconnect_or_create(provider, auth_config, opts)
      when is_binary(provider) and is_map(auth_config) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, provider_atom} <- parse_provider(provider),
         module <- Connector.connector_for(provider_atom),
         {:ok, _conn} <- module.connect(auth_config) do
      case existing_source(provider_atom, actor) do
        nil ->
          connect_and_create(provider, auth_config, opts)

        source ->
          update_existing(source, auth_config, actor)
      end
    else
      :error -> {:error, "Unknown provider"}
      {:error, reason} -> {:error, friendly_error(reason)}
    end
  end

  defp existing_source(provider_atom, actor) do
    case Knowledge.list_sources_for_user(actor: actor) do
      {:ok, sources} -> Enum.find(sources, &(&1.provider == provider_atom))
      _ -> nil
    end
  end

  defp update_existing(source, auth_config, actor) do
    with {:ok, source} <-
           Knowledge.update_source_auth_config(source, %{auth_config: auth_config}, actor: actor),
         {:ok, source} <- Knowledge.update_source_status(source, %{status: :active}, actor: actor) do
      # Clear any reauth flag so scheduled syncs resume. Best-effort: a source
      # that was never flagged still ends up active from the status update above.
      case Knowledge.clear_source_reauth(source, authorize?: false) do
        {:ok, cleared} -> {:ok, cleared}
        {:error, _} -> {:ok, source}
      end
    else
      {:error, reason} -> {:error, friendly_error(reason)}
    end
  end

  @doc """
  List folders under `parent_id` (nil = root) for an already-created source.
  Connects with the source's stored credentials each call (lazy browsing).
  """
  def list_folders(%{provider: provider} = source, parent_id) do
    if provider in supported_atoms() do
      module = Connector.connector_for(provider)

      with {:ok, conn} <- module.connect(source.auth_config),
           {:ok, folders} <- module.list_folders(conn, parent_id) do
        {:ok, folders}
      else
        {:error, reason} -> {:error, friendly_error(reason)}
      end
    else
      {:error, "Browsing folders is not supported for this provider."}
    end
  end

  defp parse_provider(provider) when provider in @providers,
    do: {:ok, String.to_existing_atom(provider)}

  defp parse_provider(_), do: :error

  defp supported_atoms, do: Enum.map(@providers, &String.to_existing_atom/1)

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp default_name(:google_drive), do: "Google Drive"
  defp default_name(:notion), do: "Notion"
  defp default_name(:nextcloud), do: "Nextcloud"
  defp default_name(:affine), do: "AFFiNE"
  defp default_name(:web), do: "Web"
  defp default_name(other), do: other |> to_string() |> String.capitalize()

  defp friendly_error(message) when is_binary(message), do: message
  defp friendly_error(:not_supported), do: "This provider does not support browsing folders."
  defp friendly_error(reason), do: "Could not connect: #{inspect(reason)}"
end
