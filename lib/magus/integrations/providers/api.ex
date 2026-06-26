defmodule Magus.Integrations.Providers.Api do
  @moduledoc """
  API channel integration provider.
  Enables external applications to interact with Magus agents via REST API.
  """

  @behaviour Magus.Integrations.Providers.Behaviour
  @behaviour Magus.Integrations.Providers.ChannelBehaviour
  @behaviour Magus.Integrations.Providers.ApiChannelBehaviour

  # --- Behaviour callbacks ---

  @impl Magus.Integrations.Providers.Behaviour
  def key, do: :api

  @impl Magus.Integrations.Providers.Behaviour
  def name, do: "API"

  @impl Magus.Integrations.Providers.Behaviour
  def description, do: "Connect apps and scripts via REST API"

  @impl Magus.Integrations.Providers.Behaviour
  def auth_type, do: :none

  @impl Magus.Integrations.Providers.Behaviour
  def source_type, do: :channel

  # --- ChannelBehaviour callbacks ---

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def default_conversation_mode, do: :multi

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def default_async_reply_enabled?, do: false

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def conversation_identifier(parsed_input) do
    case parsed_input["sender_id"] do
      nil -> {:error, :no_session_id}
      id -> {:ok, id}
    end
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def authorize_sender(_parsed_input, _integration), do: :ok

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def extract_message_content(parsed_input) do
    case parsed_input["text"] do
      nil -> {:error, :no_content}
      text -> {:ok, to_string(text)}
    end
  end

  @impl Magus.Integrations.Providers.ChannelBehaviour
  def extract_recipient_id(parsed_input) do
    {:ok, parsed_input["sender_id"]}
  end

  # --- ApiChannelBehaviour callbacks ---

  @impl Magus.Integrations.Providers.ApiChannelBehaviour
  def parse_request(params, _headers) do
    case params["content"] do
      nil ->
        {:error, :content_required}

      content ->
        session_id = params["session_id"] || generate_session_id()

        parsed = %{
          "text" => content,
          "sender_id" => session_id,
          "attachments" => params["attachments"] || [],
          "stream" => params["stream"] || false,
          "verbosity" => parse_verbosity(params["verbosity"])
        }

        {:ok, parsed}
    end
  end

  @impl Magus.Integrations.Providers.ApiChannelBehaviour
  def supports_streaming?, do: true

  @impl Magus.Integrations.Providers.ApiChannelBehaviour
  def stream_event_types(verbosity) do
    case verbosity do
      :minimal ->
        ~w(session.created message.started text.chunk message.completed error)

      :standard ->
        ~w(session.created message.started text.chunk tool.started tool.completed message.completed error)

      :full ->
        ~w(session.created message.started text.chunk thinking.chunk tool.started tool.progress tool.completed message.completed error)

      _ ->
        stream_event_types(:standard)
    end
  end

  # --- Operations ---

  @impl Magus.Integrations.Providers.Behaviour
  def operations, do: [:send_message]

  @impl Magus.Integrations.Providers.Behaviour
  def execute(:send_message, _credentials, params) do
    # API channel replies are delivered via the REST response or SSE stream,
    # not pushed externally. Just acknowledge success.
    {:ok, %{status: :delivered, message: params[:message]}}
  end

  def execute(operation, _credentials, _params) do
    {:error, {:unsupported_operation, operation}}
  end

  # --- Lifecycle ---

  @impl Magus.Integrations.Providers.Behaviour
  def on_credentials_saved(integration, _credentials) do
    api_key = generate_api_key()
    key_hash = hash_api_key(api_key)
    prefix = key_prefix(api_key)

    with {:ok, credential} <-
           Magus.Integrations.get_credential_for_integration(
             integration.id,
             authorize?: false
           ),
         {:ok, _} <-
           Magus.Integrations.refresh_credential(
             credential,
             %{encrypted_data: %{"api_key" => api_key}, key_hash: key_hash},
             authorize?: false
           ),
         {:ok, _} <-
           Magus.Integrations.update_integration_config(
             integration,
             %{config: Map.merge(integration.config || %{}, %{"key_prefix" => prefix})},
             authorize?: false
           ) do
      {:ok, %{api_key: api_key}}
    end
  end

  # --- API Key Management ---

  @doc "Generate a new API key with magus_sk_ prefix."
  def generate_api_key do
    random = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "magus_sk_#{random}"
  end

  @doc "Compute SHA-256 hash of an API key for indexed lookup."
  def hash_api_key(key) when is_binary(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  @doc "Extract the display prefix from an API key (first 17 chars: 'magus_sk_' + 8 hex)."
  def key_prefix(key) when is_binary(key) do
    String.slice(key, 0, 17)
  end

  # --- Private ---

  defp generate_session_id do
    random = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "ses_#{random}"
  end

  defp parse_verbosity("minimal"), do: :minimal
  defp parse_verbosity("standard"), do: :standard
  defp parse_verbosity("full"), do: :full
  defp parse_verbosity(_), do: :standard
end
