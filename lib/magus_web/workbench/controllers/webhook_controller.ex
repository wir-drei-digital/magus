defmodule MagusWeb.WebhookController do
  @moduledoc """
  Generic webhook endpoint that delegates to provider-specific handlers.

  URL pattern: POST /webhooks/:provider/:integration_id

  This controller handles Plug.Conn-specific concerns:
  - Loading integration with credentials
  - Webhook verification (provider-specific, needs conn)
  - Rate limiting
  - Sending provider-specific response (needs conn)

  Business logic is delegated to the ProcessWebhook reactor:
  - Parsing webhook payload
  - Creating InputMessage (triggers conversation routing)
  - Audit logging
  """

  use MagusWeb, :controller

  require Logger

  alias Magus.Integrations

  @doc """
  POST /webhooks/:provider/:integration_id
  """
  def webhook(conn, %{"provider" => provider_key_str, "integration_id" => integration_id}) do
    provider_key = parse_provider_key(provider_key_str)

    with {:ok, provider} <- get_provider_module(provider_key),
         {:ok, integration} <- get_active_integration(integration_id) do
      handle_verified_webhook(conn, provider_key, provider, integration)
    else
      {:error, :unknown_provider} ->
        Logger.debug("Webhook for unknown provider: #{provider_key}")
        send_resp(conn, 404, "Unknown provider")

      {:error, :not_found} ->
        Logger.debug("Webhook for non-existent integration: #{integration_id}")
        send_resp(conn, 404, "Integration not found")

      {:error, :inactive} ->
        Logger.debug("Webhook for inactive integration: #{integration_id}")
        send_resp(conn, 404, "Integration not active")
    end
  end

  # Once provider and integration are loaded, run the remaining pipeline.
  # Having `integration` in scope allows audit_failure to include user_id.
  defp handle_verified_webhook(conn, provider_key, provider, integration) do
    audit_opts = [integration_id: integration.id, user_id: integration.user_id]

    with :ok <- verify_webhook(provider, conn, integration),
         :ok <- check_rate_limit(integration.user_id, provider_key),
         {:ok, payload} <- get_payload(conn) do
      case provider_source_type(provider) do
        :data_source ->
          run_process_ingestion(conn, provider, integration, payload)

        :knowledge ->
          run_knowledge_sync(conn, provider, integration, payload)

        _chat ->
          case run_process_webhook(integration.user_id, provider_key, integration, payload, conn) do
            {:ok, result} ->
              conn = Plug.Conn.put_private(conn, :input_message_id, result.external_id)
              send_webhook_response(provider, conn)

            error ->
              handle_webhook_error(conn, provider_key, error, audit_opts)
          end
      end
    else
      {:error, :verification_failed} ->
        audit_failure(provider_key, conn, :verification_failed, audit_opts)
        send_resp(conn, 401, "Unauthorized")

      {:error, :rate_limited} ->
        audit_failure(provider_key, conn, :rate_limited, audit_opts)
        send_resp(conn, 429, "Rate limited")

      {:error, :invalid_json} ->
        Logger.warning("Webhook with invalid JSON: #{provider_key}/#{integration.id}")
        send_resp(conn, 400, "Invalid JSON")

      {:error, {:parse_failed, _reason}} ->
        Logger.warning("Webhook parsing failed: #{provider_key}/#{integration.id}")
        send_resp(conn, 400, "Invalid payload")

      {:error, :duplicate_message} ->
        Logger.debug("Duplicate webhook ignored: #{provider_key}/#{integration.id}")
        send_resp(conn, 200, "ok")

      {:error, reason} ->
        Logger.warning("Webhook error for #{provider_key}/#{integration.id}: #{inspect(reason)}")
        audit_failure(provider_key, conn, reason, audit_opts)
        send_resp(conn, 400, "Bad request")
    end
  end

  # Run the ProcessWebhook reactor
  defp run_process_webhook(user_id, provider_key, integration, payload, conn) do
    inputs = %{
      user_id: user_id,
      provider_key: provider_key,
      integration_id: integration.id,
      payload: payload,
      headers: conn.req_headers,
      ip_address: format_ip(conn.remote_ip)
    }

    case Reactor.run(Integrations.Reactors.ProcessWebhook, inputs, async?: false) do
      {:ok, result} -> {:ok, result}
      {:error, errors} -> {:error, extract_error(errors)}
    end
  end

  # Determine provider source type for webhook routing
  defp provider_source_type(provider_module) do
    provider_module.source_type()
  end

  # Handle knowledge source webhooks by triggering incremental sync
  defp run_knowledge_sync(conn, _provider_module, _integration, _payload) do
    # Stub — implemented when Knowledge domain connectors are built
    # Will resolve affected KnowledgeCollection and trigger incremental sync
    send_resp(conn, 200, "ok")
  end

  # Run the ProcessIngestion pipeline for data source providers
  defp run_process_ingestion(conn, provider_module, integration, payload) do
    case Magus.Integrations.ProcessIngestion.run(
           provider_module,
           integration,
           payload,
           conn.req_headers
         ) do
      {:ok, %{ingested: count}} ->
        json(conn, %{status: "ok", ingested: count})

      {:error, reason} ->
        Logger.warning("Ingestion failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "ingestion_failed"})
    end
  end

  # Handle errors from the ProcessWebhook reactor path
  defp handle_webhook_error(conn, provider_key, {:error, :duplicate_message}, _audit_opts) do
    Logger.debug("Duplicate webhook ignored: #{provider_key}")
    send_resp(conn, 200, "ok")
  end

  defp handle_webhook_error(conn, provider_key, {:error, {:parse_failed, _reason}}, _audit_opts) do
    Logger.warning("Webhook parsing failed: #{provider_key}")
    send_resp(conn, 400, "Invalid payload")
  end

  defp handle_webhook_error(conn, provider_key, {:error, reason}, audit_opts) do
    Logger.warning("Webhook error for #{provider_key}: #{inspect(reason)}")
    audit_failure(provider_key, conn, reason, audit_opts)
    send_resp(conn, 400, "Bad request")
  end

  # Extract meaningful error from reactor errors
  defp extract_error(%{errors: [first | _]}), do: first
  defp extract_error(error), do: error

  # Get provider module by key
  defp get_provider_module(provider_key) do
    case Integrations.get_provider_module(provider_key) do
      nil -> {:error, :unknown_provider}
      module -> {:ok, module}
    end
  end

  defp parse_provider_key(key) when is_atom(key), do: key

  defp parse_provider_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  # Load integration by ID with credential for webhook verification
  defp get_active_integration(integration_id) do
    case Integrations.get_user_integration(integration_id,
           authorize?: false,
           load: [:credential]
         ) do
      {:ok, %{status: :active} = integration} ->
        {:ok, integration}

      {:ok, _} ->
        {:error, :inactive}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  # Delegate verification to provider (needs conn)
  defp verify_webhook(provider, conn, integration) do
    if function_exported?(provider, :verify_webhook, 2) do
      case provider.verify_webhook(conn, integration) do
        :ok -> :ok
        {:error, _reason} -> {:error, :verification_failed}
      end
    else
      # Provider doesn't require webhook verification
      :ok
    end
  end

  # Get the parsed payload from the connection
  defp get_payload(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case conn.private[:raw_body] do
          nil -> {:error, :no_body}
          raw -> Jason.decode(raw)
        end

      params when is_map(params) and map_size(params) > 0 ->
        {:ok, params}

      _ ->
        {:error, :invalid_json}
    end
  end

  # Send provider-specific response (needs conn)
  defp send_webhook_response(provider, conn) do
    if function_exported?(provider, :webhook_response, 1) do
      provider.webhook_response(conn)
    else
      send_resp(conn, 200, "ok")
    end
  end

  # Rate limiting
  defp check_rate_limit(user_id, provider_key) do
    Integrations.RateLimiter.check(user_id, provider_key, :webhook)
  end

  # Audit failure via supervised task
  defp audit_failure(provider_key, conn, error, opts) do
    metadata =
      opts
      |> Keyword.take([:integration_id])
      |> Map.new()
      |> Map.merge(%{error: inspect(error), user_agent: get_header(conn, "user-agent")})

    user_id = Keyword.get(opts, :user_id)

    Task.Supervisor.start_child(Magus.Integrations.WebhookTaskSupervisor, fn ->
      Integrations.record_audit(
        %{
          provider_key: provider_key,
          operation: "webhook",
          status: :failure,
          ip_address: format_ip(conn.remote_ip),
          metadata: metadata
        }
        |> then(fn attrs ->
          if user_id, do: Map.put(attrs, :user_id, user_id), else: attrs
        end),
        authorize?: false
      )
    end)
  end

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip), do: to_string(ip)
end
