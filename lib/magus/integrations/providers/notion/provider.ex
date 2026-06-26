defmodule Magus.Integrations.Providers.Notion do
  @moduledoc """
  Integration provider for Notion workspaces.

  Uses Notion's public OAuth2 flow to obtain an access token scoped to
  the pages the user shares during the consent screen.

  See: https://developers.notion.com/docs/authorization
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :notion_knowledge

  @impl true
  def name, do: "Notion"

  @impl true
  def description, do: "Connect Notion workspaces for knowledge base RAG"

  @impl true
  def auth_type, do: :oauth2

  @impl true
  def oauth_config do
    %{
      authorize_url: "https://api.notion.com/v1/oauth/authorize",
      token_url: "https://api.notion.com/v1/oauth/token",
      # Notion OAuth doesn't use scopes — access is granted per-page during consent
      scopes: [],
      client_id: System.get_env("NOTION_CLIENT_ID"),
      client_secret: System.get_env("NOTION_CLIENT_SECRET"),
      # Notion uses owner=user to request user-level tokens
      extra_authorize_params: %{owner: "user"},
      # Notion requires HTTP Basic auth for token exchange instead of POST body
      token_auth_method: :basic
    }
  end

  @impl true
  def auth_help do
    %{
      text: "You'll be redirected to Notion to select which pages and databases to share.",
      url: "https://developers.notion.com/docs/authorization",
      url_label: "Notion Authorization Docs"
    }
  end

  @impl true
  def operations, do: []

  @impl true
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

  @impl true
  def source_type, do: :knowledge
end
