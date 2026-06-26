defmodule Magus.Integrations.Providers.CustomApi.Provider do
  @moduledoc """
  Custom API integration provider.

  Allows agents to call arbitrary external HTTP APIs. Each integration
  instance represents one configured API endpoint (e.g. Jira, GitHub, Stripe).
  Multiple custom_api integrations may be attached to the same agent, one per
  external service.

  Authentication is via API key stored encrypted in the Credential resource.
  The base URL and any additional headers are stored in the integration config.
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :custom_api

  @impl true
  def name, do: "Custom API"

  @impl true
  def description do
    "Connect to any external HTTP API. Configure the base URL, authentication, and let your agent make requests."
  end

  @impl true
  def auth_type, do: :api_key

  @impl true
  def source_type, do: :tool_provider

  @impl true
  def requires_admin?, do: true

  @impl true
  def tools, do: []

  @impl true
  def auth_fields, do: []

  @impl true
  def execute(_operation, _credentials, _params) do
    {:error, :not_supported}
  end
end
