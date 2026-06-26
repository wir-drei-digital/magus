defmodule Magus.Agents.Tools.Integrations.ConfigureApiIntegration do
  use Jido.Action,
    name: "configure_api_integration",
    description: """
    Create or update a custom API integration on an agent.
    Configures the API's base URL, authentication method, and endpoint documentation.
    Does NOT handle credentials — the user must add those in agent settings.
    """,
    schema: [
      custom_agent_id: [type: :string, required: true, doc: "Target agent ID"],
      name: [type: :string, required: true, doc: "API service name (e.g., Jira, GitHub)"],
      base_url: [type: :string, required: true, doc: "Base URL for all endpoints"],
      auth_method: [
        type: {:in, ["bearer", "api_key_header", "basic", "none"]},
        required: true,
        doc: "Authentication method"
      ],
      auth_header_name: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Custom header name for api_key_header auth"
      ],
      default_headers: [
        type: :map,
        default: %{},
        doc: "Default headers for all requests"
      ],
      endpoints: [
        type: {:list, :map},
        required: true,
        doc: "Endpoint documentation"
      ]
    ]

  require Logger
  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_context_value: 2]

  def display_name, do: "Configuring API integration..."

  def summarize_output(%{name: name, endpoints_count: n}),
    do: "Configured #{name} (#{n} endpoints)"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    agent_id = get_param(params, :custom_agent_id)
    user_id = get_context_value(context, :user_id)

    case load_and_verify_agent(agent_id, user_id) do
      {:ok, agent} ->
        config = build_config(params)
        name = get_param(params, :name)

        case find_existing_integration(agent.id, name) do
          {:ok, existing} -> update_integration(existing, config)
          :not_found -> create_integration(agent, user_id, config)
        end

      {:error, reason} ->
        {:ok, %{error: reason}}
    end
  end

  defp load_and_verify_agent(agent_id, user_id) do
    case Magus.Agents.get_custom_agent(agent_id, authorize?: false) do
      {:ok, agent} ->
        if agent.user_id == user_id,
          do: {:ok, agent},
          else: {:error, "Unauthorized: agent does not belong to this user"}

      _ ->
        {:error, "Agent not found"}
    end
  end

  defp build_config(params) do
    %{
      "name" => get_param(params, :name),
      "base_url" => get_param(params, :base_url),
      "auth_method" => get_param(params, :auth_method),
      "auth_header_name" => get_param(params, :auth_header_name),
      "default_headers" => get_param(params, :default_headers) || %{},
      "endpoints" => get_param(params, :endpoints) || []
    }
  end

  defp find_existing_integration(agent_id, name) do
    case Magus.Integrations.list_by_agent_and_provider(agent_id, :custom_api, authorize?: false) do
      {:ok, integrations} ->
        case Enum.find(integrations, fn i -> i.config["name"] == name end) do
          nil -> :not_found
          existing -> {:ok, existing}
        end

      _ ->
        :not_found
    end
  end

  defp update_integration(integration, config) do
    case Magus.Integrations.update_integration_config(integration, %{config: config},
           authorize?: false
         ) do
      {:ok, updated} ->
        {:ok, build_result(updated, config)}

      {:error, reason} ->
        Logger.warning("Failed to update custom API integration: #{inspect(reason)}")
        {:ok, %{error: "Failed to update integration"}}
    end
  end

  defp create_integration(agent, user_id, config) do
    case Magus.Integrations.create_user_integration(
           :custom_api,
           %{user_id: user_id, custom_agent_id: agent.id, config: config},
           authorize?: false
         ) do
      {:ok, integration} ->
        {:ok, build_result(integration, config)}

      {:error, reason} ->
        Logger.warning("Failed to create custom API integration: #{inspect(reason)}")
        {:ok, %{error: "Failed to create integration"}}
    end
  end

  defp build_result(integration, config) do
    endpoints = config["endpoints"] || []

    %{
      integration_id: integration.id,
      name: config["name"],
      endpoints_count: length(endpoints),
      status: to_string(integration.status),
      message:
        "Integration configured. Please add your API credentials in the agent settings to activate it."
    }
  end
end
