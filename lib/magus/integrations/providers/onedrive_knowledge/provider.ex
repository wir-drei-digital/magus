defmodule Magus.Integrations.Providers.OneDriveKnowledge do
  @moduledoc """
  Integration provider for OneDrive knowledge sources.

  Enables OAuth2-based credential management for Microsoft OneDrive.
  Used by the Knowledge domain's OneDrive connector for RAG sync.
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :onedrive_knowledge

  @impl true
  def name, do: "OneDrive"

  @impl true
  def description, do: "Connect OneDrive folders for knowledge base RAG"

  @impl true
  def auth_type, do: :oauth2

  @impl true
  def oauth_config do
    %{
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scopes: ["Files.Read", "offline_access"],
      client_id: System.get_env("ONEDRIVE_CLIENT_ID"),
      client_secret: System.get_env("ONEDRIVE_CLIENT_SECRET")
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
