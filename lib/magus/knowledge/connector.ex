defmodule Magus.Knowledge.Connector do
  @moduledoc """
  Behaviour for knowledge source connectors.
  Each provider implements this behaviour. Connections are short-lived —
  created at the start of each sync job, not persisted between jobs.
  """

  @typedoc "An opaque connection value returned by `connect/1` and passed to subsequent callbacks."
  @type connection :: term()

  @typedoc "A folder (or container) in the remote knowledge source."
  @type folder :: %{id: String.t(), name: String.t(), path: String.t()}

  @typedoc "A single item (document, page, file) in the remote knowledge source."
  @type item :: %{
          id: String.t(),
          name: String.t(),
          etag: String.t(),
          updated_at: DateTime.t(),
          mime_type: String.t()
        }

  @typedoc "A detected change for an item in the remote knowledge source."
  @type change :: %{type: :created | :updated | :deleted, item: item()}

  @doc """
  Establish a connection to the remote knowledge source using the given auth config.

  The returned `connection` value is opaque and connector-specific. It is
  passed to all other callbacks for the lifetime of a single sync job.
  """
  @callback connect(auth_config :: map()) :: {:ok, connection()} | {:error, term()}

  @doc """
  List folders (containers) available at the given path.

  Pass `nil` for `path` to list top-level folders.
  """
  @callback list_folders(connection(), path :: String.t() | nil) ::
              {:ok, [folder()]} | {:error, term()}

  @doc """
  List items in the given collection, with optional cursor-based pagination.

  `cursor` is `nil` for the first page; pass the `new_cursor` from the previous
  call to advance. Returns `new_cursor` of `nil` when there are no more pages.
  """
  @callback list_items(connection(), collection :: map(), cursor :: map() | nil) ::
              {:ok, [item()], new_cursor :: map() | nil} | {:error, term()}

  @doc """
  Fetch the binary content and metadata for a single item.
  """
  @callback fetch_content(connection(), item :: map()) ::
              {:ok, binary(), metadata :: map()} | {:error, term()}

  @doc """
  Return items that have changed in the given collection since the given timestamp.

  Returns `{:error, :not_supported}` if the provider does not support change detection.
  """
  @callback detect_changes(connection(), collection :: map(), since :: DateTime.t()) ::
              {:ok, [change()]}
              | {:ok, [change()], cursor :: map()}
              | {:error, :not_supported}
              | {:error, term()}

  @doc """
  Register a webhook for the given collection so that the provider pushes change
  notifications to `callback_url`.

  Returns `{:error, :not_supported}` if the provider does not support webhooks.
  """
  @callback register_webhook(connection(), collection :: map(), callback_url :: String.t()) ::
              {:ok, webhook_id :: String.t()} | {:error, :not_supported} | {:error, term()}

  @doc """
  Create a new item in the given collection with the given name, binary content,
  and metadata.

  Returns `{:error, :not_supported}` if the provider is read-only.
  """
  @callback create_item(
              connection(),
              collection :: map(),
              name :: String.t(),
              content :: binary(),
              metadata :: map()
            ) :: {:ok, item()} | {:error, :not_supported} | {:error, term()}

  @doc """
  Update an existing item identified by `external_id` in the given collection.

  Returns `{:error, :not_supported}` if the provider is read-only.
  """
  @callback update_item(
              connection(),
              collection :: map(),
              external_id :: String.t(),
              content :: binary(),
              metadata :: map()
            ) :: {:ok, item()} | {:error, :not_supported} | {:error, term()}

  @doc """
  Whether `detect_changes/3` emits `:deleted` changes.

  Connectors whose delta feed has no deletion signal (for example Notion
  database queries filtered by last_edited_time) return false or omit the
  callback; the sync framework then reconciles deletions with a full-listing
  diff after applying delta changes.
  """
  @callback deletes_in_delta?() :: boolean()

  @optional_callbacks deletes_in_delta?: 0

  @doc """
  Return the connector module for the given provider atom.

  ## Examples

      iex> Magus.Knowledge.Connector.connector_for(:google_drive)
      Magus.Knowledge.Connectors.GoogleDrive

      iex> Magus.Knowledge.Connector.connector_for(:unknown)
      {:error, {:unsupported_provider, :unknown}}

  """
  def connector_for(:google_drive), do: Magus.Knowledge.Connectors.GoogleDrive
  def connector_for(:onedrive), do: Magus.Knowledge.Connectors.Onedrive
  def connector_for(:dropbox), do: Magus.Knowledge.Connectors.Dropbox
  def connector_for(:notion), do: Magus.Knowledge.Connectors.Notion
  def connector_for(:nextcloud), do: Magus.Knowledge.Connectors.Nextcloud
  def connector_for(:kdrive), do: Magus.Knowledge.Connectors.Kdrive
  def connector_for(:affine), do: Magus.Knowledge.Connectors.Affine
  def connector_for(:web), do: Magus.Knowledge.Connectors.Web
  def connector_for(provider), do: {:error, {:unsupported_provider, provider}}
end
