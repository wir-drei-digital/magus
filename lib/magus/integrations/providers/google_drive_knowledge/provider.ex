defmodule Magus.Integrations.Providers.GoogleDriveKnowledge do
  @moduledoc """
  Integration provider for Google Drive knowledge sources.

  Enables OAuth2-based credential management for Google Drive.
  Used by the Knowledge domain's Google Drive connector for RAG sync.
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :google_drive_knowledge

  @impl true
  def name, do: "Google Drive"

  @impl true
  def description, do: "Connect Google Drive folders for knowledge base RAG"

  @impl true
  def auth_type, do: :oauth2

  @impl true
  def oauth_config do
    %{
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      scopes: ["https://www.googleapis.com/auth/drive.readonly"],
      client_id: System.get_env("GOOGLE_CLIENT_ID"),
      client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
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
