defmodule Magus.Integrations.Providers.Behaviour do
  @moduledoc """
  Base behaviour that all integration providers must implement.

  Defines provider metadata and authentication. Webhook handling and
  conversation routing live in `ChannelBehaviour` (for `:channel` providers).

  ## Source Types

  Every provider declares a `source_type/0`:

  - `:channel`        — bidirectional messaging (Telegram, SimpleWebhook)
  - `:tool_provider`  — exposes tools to the agent (Google Calendar)
  - `:data_source`    — streaming data ingestion (logs, RSS)
  - `:knowledge`      — document sync for RAG (Notion, Google Drive, Nextcloud, Affine)

  ## Implementing a Provider

  ```elixir
  defmodule MyApp.Integrations.Providers.MyProvider do
    @behaviour Magus.Integrations.Providers.Behaviour

    @impl true
    def key, do: :my_provider

    @impl true
    def name, do: "My Provider"

    @impl true
    def description, do: "Does something useful"

    @impl true
    def auth_type, do: :api_key

    @impl true
    def source_type, do: :tool_provider

    @impl true
    def operations, do: [:do_thing]

    @impl true
    def execute(:do_thing, credentials, params) do
      {:ok, %{result: "done"}}
    end
  end
  ```
  """

  # ---------------------------------------------------------------------------
  # Required callbacks
  # ---------------------------------------------------------------------------

  @doc "Unique identifier for the provider (e.g., :telegram, :google_calendar)"
  @callback key() :: atom()

  @doc "Human-readable name for display"
  @callback name() :: String.t()

  @doc "Description of the provider's capabilities"
  @callback description() :: String.t()

  @doc "Authentication method"
  @callback auth_type() :: :oauth2 | :api_key | :imap | :webhook_only | :none

  @doc "Provider classification for routing and UI purposes"
  @callback source_type() :: :channel | :tool_provider | :data_source | :knowledge

  # ---------------------------------------------------------------------------
  # Optional callbacks
  # ---------------------------------------------------------------------------

  @doc """
  List of tool modules provided by this integration.

  Each tool module should implement the Jido.Action behaviour.
  Tools are made available to the conversation agent when the integration
  is enabled and the specific tool is enabled by the user.

  Returns a list of tool definitions:
  ```elixir
  [
    %{
      key: :list_calendar_events,
      module: MyApp.Agents.Tools.GoogleCalendar.ListEvents,
      name: "List Calendar Events",
      description: "Retrieve events from Google Calendar"
    }
  ]
  ```
  """
  @callback tools() :: [map()]

  @doc "List of supported operations (e.g., [:send_message, :list_events])"
  @callback operations() :: [atom()]

  @doc """
  Execute a provider operation with the given credentials and parameters.

  The credentials map contains decrypted credential data (access_token, api_key, etc.).
  The params map contains operation-specific parameters.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback execute(operation :: atom(), credentials :: map(), params :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  For API key providers, defines the fields needed for authentication.

  Returns a list of field definitions:
  ```elixir
  [
    %{name: :bot_token, label: "Bot Token", type: :password,
      help: "Get this from @BotFather on Telegram"}
  ]
  ```
  """
  @callback auth_fields() :: [map()]

  @doc """
  For OAuth2 providers, returns the OAuth configuration.

  ```elixir
  %{
    authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    scopes: ["https://www.googleapis.com/auth/calendar"],
    client_id: System.get_env("GOOGLE_CLIENT_ID"),
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
  }
  ```
  """
  @callback oauth_config() :: map()

  @doc """
  Called when credentials are saved for this provider.

  Use this to perform initial setup, like setting up webhooks for Telegram.
  Returns `{:ok, additional_config}` to merge into the integration's config,
  or `{:error, reason}` if setup failed.
  """
  @callback on_credentials_saved(user_integration :: map(), credentials :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Called when credentials are removed for this provider.

  Use this to clean up, like removing webhooks.
  """
  @callback on_credentials_removed(user_integration :: map(), credentials :: map()) ::
              :ok | {:error, term()}

  @doc """
  Whether this provider requires admin privileges to connect.

  When `true`, the provider is only shown to admin users in the UI.
  Defaults to `false`.
  """
  @callback requires_admin?() :: boolean()

  @doc """
  Optional help text shown during authentication setup.

  Returns a map with:
    * `:text` - Brief instructions on how to obtain credentials
    * `:url` - (optional) Link to the provider's documentation
    * `:url_label` - (optional) Label for the link, defaults to "Documentation"

  Example:
  ```elixir
  %{
    text: "Create an internal integration at notion.so/my-integrations and copy the token.",
    url: "https://developers.notion.com/docs/create-a-notion-integration",
    url_label: "Notion Developer Docs"
  }
  ```
  """
  @callback auth_help() :: map()

  @optional_callbacks [
    tools: 0,
    operations: 0,
    execute: 3,
    auth_fields: 0,
    oauth_config: 0,
    on_credentials_saved: 2,
    on_credentials_removed: 2,
    requires_admin?: 0,
    auth_help: 0
  ]
end
