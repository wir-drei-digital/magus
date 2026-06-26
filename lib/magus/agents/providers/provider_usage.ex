defmodule Magus.Agents.Providers.ProviderUsage do
  @moduledoc """
  Fetches usage and billing information from external API providers.

  Supported providers:
  - OpenRouter: Account balance and usage
  - Exa.AI: API key usage and costs
  - AIML API: Account balance
  - PublicAI: No API (direct link only)
  """

  require Logger

  @openrouter_balance_url "https://openrouter.ai/api/v1/credits"
  @exa_usage_url "https://admin-api.exa.ai/team-management/api-keys"
  @aimlapi_balance_url "https://api.aimlapi.com/v1/billing/balance"

  @type provider :: :openrouter | :exa | :aimlapi | :publicai | :fal

  @type usage_result :: %{
          provider: provider(),
          balance: Decimal.t() | nil,
          total_funded: Decimal.t() | nil,
          total_usage: Decimal.t() | nil,
          cost_breakdown: list(map()) | nil,
          last_updated: DateTime.t() | nil,
          error: String.t() | nil,
          note: String.t() | nil
        }

  @doc """
  Fetches usage information from all configured providers.

  Returns a list of usage results for each provider.
  """
  @fetch_timeout 30_000

  @spec fetch_all() :: list(usage_result())
  def fetch_all do
    # Pair each task with its provider atom so a timed-out / crashed fetch can
    # fall back to a well-formed usage_result (the template requires :provider).
    labeled_tasks = [
      {:openrouter, Task.async(fn -> fetch_openrouter() end)},
      {:exa, Task.async(fn -> fetch_exa() end)},
      {:aimlapi, Task.async(fn -> fetch_aimlapi() end)},
      {:publicai, Task.async(fn -> fetch_publicai() end)},
      {:fal, Task.async(fn -> fetch_fal() end)}
    ]

    tasks = Enum.map(labeled_tasks, fn {_provider, task} -> task end)

    # yield_many never exits the caller (unlike await_many), so a hung fetch
    # degrades to a per-provider error instead of crashing the LiveView.
    results = Task.yield_many(tasks, timeout: @fetch_timeout)

    Enum.map(labeled_tasks, fn {provider, task} ->
      case List.keyfind(results, task, 0) do
        {^task, {:ok, result}} ->
          result

        {^task, {:exit, reason}} ->
          Logger.error("#{provider} usage fetch crashed: #{inspect(reason)}")
          timeout_result(provider, "Request failed: #{inspect(reason)}")

        _ ->
          # nil yield: the task is still running past the timeout. Kill it and
          # report a timeout for this provider.
          Task.shutdown(task, :brutal_kill)
          timeout_result(provider, "timed out")
      end
    end)
  end

  # A well-formed usage_result for a provider whose fetch timed out or crashed.
  defp timeout_result(provider, error) do
    %{
      provider: provider,
      balance: nil,
      total_credits: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: error,
      note: nil
    }
  end

  @doc """
  Fetches balance and usage from OpenRouter.

  API: GET https://openrouter.ai/api/v1/credits
  Returns funded amount and total usage.
  """
  @spec fetch_openrouter() :: usage_result()
  def fetch_openrouter do
    base_result = %{
      provider: :openrouter,
      balance: nil,
      total_funded: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: nil,
      note: nil
    }

    case System.get_env("OPENROUTER_API_KEY") do
      nil ->
        %{base_result | error: "OPENROUTER_API_KEY not configured"}

      api_key ->
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]

        case Req.get(@openrouter_balance_url, headers: headers, receive_timeout: 15_000) do
          {:ok, %{status: 200, body: %{"data" => data}}} ->
            total_funded = parse_decimal(data["total_credits"])
            total_usage = parse_decimal(data["total_usage"])
            balance = Decimal.sub(total_funded, total_usage)

            %{
              base_result
              | balance: balance,
                total_funded: total_funded,
                total_usage: total_usage
            }

          {:ok, %{status: status, body: body}} ->
            Logger.warning("OpenRouter balance API returned #{status}: #{inspect(body)}")
            %{base_result | error: "API returned status #{status}"}

          {:error, error} ->
            Logger.error("Failed to fetch OpenRouter balance: #{inspect(error)}")
            %{base_result | error: "Request failed: #{inspect(error)}"}
        end
    end
  end

  @doc """
  Fetches usage from Exa.AI.

  API: GET https://admin-api.exa.ai/team-management/api-keys/{id}/usage
  Requires EXA_API_KEY and EXA_API_KEY_ID environment variables.
  """
  @spec fetch_exa() :: usage_result()
  def fetch_exa do
    base_result = %{
      provider: :exa,
      balance: nil,
      total_funded: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: nil,
      note: "Usage for the last 30 days"
    }

    api_service_key = System.get_env("EXA_SERVICE_KEY")
    api_key_id = System.get_env("EXA_API_KEY")

    cond do
      is_nil(api_service_key) ->
        %{base_result | error: "EXA_SERVICE_KEY not configured"}

      is_nil(api_key_id) ->
        %{base_result | error: "EXA_API_KEY not configured"}

      true ->
        fetch_exa_usage(api_service_key, api_key_id, base_result)
    end
  end

  defp fetch_exa_usage(api_service_key, api_key_id, base_result) do
    # Get usage for the last 30 days
    end_date = DateTime.utc_now() |> DateTime.to_iso8601()
    start_date = DateTime.utc_now() |> DateTime.add(-30, :day) |> DateTime.to_iso8601()

    url = "#{@exa_usage_url}/#{api_key_id}/usage?start_date=#{start_date}&end_date=#{end_date}"

    headers = [
      {"x-api-key", api_service_key},
      {"Content-Type", "application/json"}
    ]

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} ->
        total_cost = parse_decimal(body["total_cost_usd"])
        cost_breakdown = body["cost_breakdown"] || []

        %{
          base_result
          | total_usage: total_cost,
            cost_breakdown: cost_breakdown
        }

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Exa usage API returned #{status}: #{inspect(body)}")
        %{base_result | error: "API returned status #{status}"}

      {:error, error} ->
        Logger.error("Failed to fetch Exa usage: #{inspect(error)}")
        %{base_result | error: "Request failed: #{inspect(error)}"}
    end
  end

  @doc """
  Fetches account balance from AIML API.

  API: GET https://api.aimlapi.com/v1/billing/balance
  """
  @spec fetch_aimlapi() :: usage_result()
  def fetch_aimlapi do
    base_result = %{
      provider: :aimlapi,
      balance: nil,
      total_funded: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: nil,
      note: "Balance shown in provider units"
    }

    case System.get_env("AIML_API_KEY") do
      nil ->
        %{base_result | error: "AIML_API_KEY not configured"}

      api_key ->
        headers = [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]

        case Req.get(@aimlapi_balance_url, headers: headers, receive_timeout: 15_000) do
          {:ok, %{status: 200, body: body}} ->
            balance = parse_decimal(body["balance"])

            last_updated =
              case body["lastUpdated"] do
                nil -> DateTime.utc_now()
                ts -> DateTime.from_iso8601(ts) |> elem(1)
              end

            %{
              base_result
              | balance: balance,
                last_updated: last_updated
            }

          {:ok, %{status: status, body: body}} ->
            Logger.warning("AIML API balance returned #{status}: #{inspect(body)}")
            %{base_result | error: "API returned status #{status}"}

          {:error, error} ->
            Logger.error("Failed to fetch AIML API balance: #{inspect(error)}")
            %{base_result | error: "Request failed: #{inspect(error)}"}
        end
    end
  end

  @doc """
  Returns info for PublicAI (no API available, just a link to their billing page).
  """
  @spec fetch_publicai() :: usage_result()
  def fetch_publicai do
    %{
      provider: :publicai,
      balance: nil,
      total_funded: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: "No API available - visit https://platform.publicai.co/billing",
      note: nil
    }
  end

  @doc """
  Returns info for Fal (no API available for usage tracking).
  """
  @spec fetch_fal() :: usage_result()
  def fetch_fal do
    %{
      provider: :fal,
      balance: nil,
      total_funded: nil,
      total_usage: nil,
      cost_breakdown: nil,
      last_updated: DateTime.utc_now(),
      error: "No API available for usage tracking",
      note: nil
    }
  end

  @doc """
  Returns the billing dashboard URL for a provider.
  """
  @spec billing_url(provider()) :: String.t() | nil
  def billing_url(:openrouter), do: "https://openrouter.ai/credits"
  def billing_url(:exa), do: "https://dashboard.exa.ai/usage"
  def billing_url(:aimlapi), do: "https://aimlapi.com/app/billing"
  def billing_url(:publicai), do: "https://platform.publicai.co/billing"
  def billing_url(:fal), do: "https://fal.ai/dashboard/billing"
  def billing_url(_), do: nil

  @doc """
  Returns a human-readable name for a provider.
  """
  @spec provider_name(provider()) :: String.t()
  def provider_name(:openrouter), do: "OpenRouter"
  def provider_name(:exa), do: "Exa.AI"
  def provider_name(:aimlapi), do: "AIML API"
  def provider_name(:publicai), do: "PublicAI"
  def provider_name(:fal), do: "Fal"
  def provider_name(provider), do: to_string(provider)

  # Parse a value to Decimal
  defp parse_decimal(nil), do: Decimal.new("0")
  defp parse_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp parse_decimal(_), do: Decimal.new("0")
end
