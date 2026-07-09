defmodule Magus.Integrations.Providers.DropboxKnowledge do
  @moduledoc """
  Integration provider for Dropbox knowledge sources.

  Enables OAuth2-based credential management for Dropbox.
  Used by the Knowledge domain's Dropbox connector for RAG sync.

  Dropbox issues refresh tokens only when the authorize request carries
  `token_access_type=offline`, so `oauth_config/0` sets it via
  `extra_authorize_params` (merged into the authorize URL by the shared
  `MagusWeb.OAuthController`).
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :dropbox_knowledge

  @impl true
  def name, do: "Dropbox"

  @impl true
  def description, do: "Connect Dropbox folders for knowledge base RAG"

  @impl true
  def auth_type, do: :oauth2

  @impl true
  def oauth_config do
    %{
      authorize_url: "https://www.dropbox.com/oauth2/authorize",
      token_url: "https://api.dropboxapi.com/oauth2/token",
      scopes: ["files.metadata.read", "files.content.read"],
      client_id: System.get_env("DROPBOX_APP_KEY"),
      client_secret: System.get_env("DROPBOX_APP_SECRET"),
      extra_authorize_params: %{token_access_type: "offline"}
    }
  end

  @impl true
  def operations, do: []

  @impl true
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

  @impl true
  def source_type, do: :knowledge

  @impl true
  def requires_admin?, do: true
end
