defmodule Magus.Integrations.Providers.Nextcloud do
  @moduledoc """
  Integration provider for Nextcloud knowledge sources.

  Enables credential management for Nextcloud instances via
  username/password (or app token) authentication. Used by the
  Knowledge domain's Nextcloud connector for RAG sync.
  """

  @behaviour Magus.Integrations.Providers.Behaviour

  @impl true
  def key, do: :nextcloud_knowledge

  @impl true
  def name, do: "Nextcloud"

  @impl true
  def description, do: "Connect Nextcloud folders for knowledge base RAG"

  @impl true
  def auth_type, do: :api_key

  @impl true
  def auth_fields do
    [
      %{
        key: "base_url",
        label: "Nextcloud URL",
        type: :text,
        required: true,
        help: "Your Nextcloud instance URL, e.g. https://cloud.example.com"
      },
      %{
        key: "username",
        label: "Username",
        type: :text,
        required: true,
        help: "Your Nextcloud username"
      },
      %{
        key: "password",
        label: "Password / App Token",
        type: :password,
        required: true,
        help: "Your password or an app-specific password from Nextcloud settings"
      }
    ]
  end

  @impl true
  def auth_help do
    %{
      text: "Use your Nextcloud credentials or create an app password under Settings > Security.",
      url:
        "https://docs.nextcloud.com/server/latest/user_manual/en/session_management.html#managing-devices",
      url_label: "Nextcloud Docs"
    }
  end

  @impl true
  def operations, do: []

  @impl true
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

  @impl true
  def source_type, do: :knowledge
end
