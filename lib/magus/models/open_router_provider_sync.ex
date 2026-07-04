defmodule Magus.Models.OpenRouterProviderSync do
  @moduledoc """
  Fetches the public OpenRouter provider list and upserts
  `Magus.Models.OpenRouterProvider` rows. Triggered on demand from the admin
  UI, not on a schedule. The `allowed` flag is preserved across syncs (see
  the resource `:upsert` action). Providers that vanish from the payload keep
  their rows and their stale `last_synced_at`.
  """
  require Logger

  @endpoint "https://openrouter.ai/api/v1/providers"

  @spec sync() :: {:ok, %{synced: non_neg_integer()}} | {:error, term()}
  def sync do
    with {:ok, providers} <- fetch() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      count =
        Enum.reduce(providers, 0, fn raw, acc ->
          case upsert(raw, now) do
            {:ok, _} ->
              acc + 1

            {:error, reason} ->
              Logger.warning(
                "OpenRouterProviderSync: skipped #{inspect(raw["slug"])}: #{inspect(reason)}"
              )

              acc
          end
        end)

      {:ok, %{synced: count}}
    end
  end

  defp fetch do
    opts =
      [
        url: @endpoint,
        receive_timeout: 15_000,
        retry: false
      ] ++ Application.get_env(:magus, :openrouter_providers_req_options, [])

    case Req.get(opts) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, data}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert(%{"slug" => slug, "name" => name} = raw, now)
       when is_binary(slug) and slug != "" and is_binary(name) do
    Magus.Models.upsert_open_router_provider(
      %{
        slug: slug,
        name: name,
        headquarters: raw["headquarters"],
        datacenters: raw["datacenters"] || [],
        privacy_policy_url: raw["privacy_policy_url"],
        terms_of_service_url: raw["terms_of_service_url"],
        status_page_url: raw["status_page_url"],
        last_synced_at: now
      },
      authorize?: false
    )
  end

  defp upsert(_raw, _now), do: {:error, :missing_slug_or_name}
end
