defmodule Magus.Knowledge.Connectors.Affine do
  @moduledoc """
  Knowledge connector for Affine Cloud.

  **Status: Stub** — The Affine Cloud API is not yet mature enough for full
  integration. This module satisfies the `Connector` behaviour contract and
  establishes a connection, but all data operations return
  `{:error, :not_supported}`.

  Once the Affine API stabilises, the callbacks will be implemented to list
  workspaces, enumerate pages, and fetch page content.

  ## Auth Config

      %{"api_key" => "af_…", "base_url" => "https://app.affine.pro"}
  """

  @behaviour Magus.Knowledge.Connector

  defstruct [:api_key, :base_url]

  @default_base_url "https://app.affine.pro"

  # --- Connector callbacks ---

  @impl true
  def connect(%{"api_key" => api_key} = config)
      when is_binary(api_key) and api_key != "" do
    base_url =
      case Map.get(config, "base_url") do
        url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
        _ -> @default_base_url
      end

    {:ok, %__MODULE__{api_key: api_key, base_url: base_url}}
  end

  def connect(_auth_config) do
    {:error, :missing_api_key}
  end

  @impl true
  def list_folders(_conn, _path) do
    {:error, :not_supported}
  end

  @impl true
  def list_items(_conn, _collection, _cursor) do
    {:error, :not_supported}
  end

  @impl true
  def fetch_content(_conn, _item) do
    {:error, :not_supported}
  end

  @impl true
  def detect_changes(_conn, _collection, _since) do
    {:error, :not_supported}
  end

  @impl true
  def register_webhook(_conn, _collection, _callback_url) do
    {:error, :not_supported}
  end

  @impl true
  def create_item(_conn, _collection, _name, _content, _metadata) do
    {:error, :not_supported}
  end

  @impl true
  def update_item(_conn, _collection, _external_id, _content, _metadata) do
    {:error, :not_supported}
  end
end
