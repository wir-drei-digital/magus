defmodule Magus.Integrations.Providers.Affine do
  @moduledoc """
  Integration provider for Affine Cloud knowledge sources.

  **Status: Stub** — The Affine Cloud API is not yet mature enough for full
  integration. This provider registers credentials but the matching connector
  returns `{:error, :not_implemented}` for data operations.
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :affine_knowledge

  @impl true
  def name, do: "Affine"

  @impl true
  def description, do: "Connect Affine workspaces for knowledge base RAG (coming soon)"

  @impl true
  def auth_type, do: :api_key

  @impl true
  def auth_fields do
    [
      %{
        key: "api_key",
        label: "API Key",
        type: :password,
        required: true,
        help: "Your Affine Cloud API key"
      },
      %{
        key: "base_url",
        label: "Base URL",
        type: :text,
        required: false,
        help: "Affine instance URL (defaults to https://app.affine.pro)"
      }
    ]
  end

  @impl true
  def operations, do: []

  @impl true
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

  @impl true
  def source_type, do: :knowledge
end
