defmodule Magus.Models.HealthCheck do
  @moduledoc """
  Cheap provider connectivity/credential probe for the admin UI: lists the
  provider's models endpoint (OpenAI-compatible `GET /models`; Anthropic
  uses `x-api-key` + `anthropic-version`). Returns `{:ok, %{models: n}}`
  or `{:error, human_message}`.

  Credentials resolve from the provider's encrypted `api_key`; when absent,
  ReqLLM's env-var convention is consulted via `ReqLLM.Keys.get/2`. Error
  messages never contain the key value.
  """

  alias Magus.Models.Provider

  @anthropic_version "2023-06-01"
  @receive_timeout 10_000

  @spec test_provider(Provider.t(), keyword()) ::
          {:ok, %{models: non_neg_integer()}} | {:error, String.t()}
  def test_provider(%Provider{} = provider, opts \\ []) do
    with {:ok, base_url} <- base_url(provider),
         {:ok, headers} <- auth_headers(provider) do
      req_opts =
        [
          url: models_url(provider, base_url),
          headers: headers,
          receive_timeout: @receive_timeout,
          retry: false
        ]
        |> Keyword.merge(Keyword.take(opts, [:plug]))

      case Req.get(req_opts) do
        {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
          {:ok, %{models: length(models)}}

        {:ok, %{status: 200}} ->
          {:ok, %{models: 0}}

        {:ok, %{status: status}} ->
          {:error, "provider responded with HTTP #{status}"}

        {:error, exception} ->
          {:error, Exception.message(exception)}
      end
    end
  end

  # Builds the models-listing URL. Anthropic's models endpoint lives under
  # `/v1/models`, but its base URL (whether the ReqLLM default or an
  # admin-stored value) is `https://api.anthropic.com` with no `/v1` prefix
  # (ReqLLM appends `/v1/...` itself per request). So for the anthropic kind
  # we ensure the probe path ends in `/v1/models` regardless of how the base
  # URL was supplied. OpenAI-compatible providers store the `/v1` (or other
  # prefix) in their base URL, so they only need `/models` appended.
  defp models_url(%Provider{req_llm_id: "anthropic"}, base_url) do
    base = String.trim_trailing(base_url, "/")

    if String.ends_with?(base, "/v1") do
      base <> "/models"
    else
      base <> "/v1/models"
    end
  end

  defp models_url(%Provider{}, base_url) do
    String.trim_trailing(base_url, "/") <> "/models"
  end

  defp base_url(%Provider{base_url: url}) when is_binary(url) and url != "", do: {:ok, url}

  defp base_url(%Provider{req_llm_id: req_llm_id}) do
    with {:ok, provider_atom} <- existing_atom(req_llm_id),
         {:ok, module} <- ReqLLM.Providers.get(provider_atom),
         true <- function_exported?(module, :default_base_url, 0),
         # Some ReqLLM providers define `default_base_url: ""`; treat an empty
         # default as "no base URL" rather than letting it fall through.
         url when is_binary(url) and url != "" <- module.default_base_url() do
      {:ok, url}
    else
      _ -> {:error, "no base URL configured and no ReqLLM default for #{req_llm_id}"}
    end
  end

  defp auth_headers(%Provider{req_llm_id: "anthropic"} = provider) do
    with {:ok, key} <- api_key(provider) do
      {:ok, [{"x-api-key", key}, {"anthropic-version", @anthropic_version}]}
    end
  end

  defp auth_headers(%Provider{} = provider) do
    with {:ok, key} <- api_key(provider) do
      {:ok, [{"authorization", "Bearer " <> key}]}
    end
  end

  defp api_key(%Provider{api_key: key}) when is_binary(key) and key != "", do: {:ok, key}

  defp api_key(%Provider{req_llm_id: req_llm_id}) do
    with {:ok, provider_atom} <- existing_atom(req_llm_id),
         {:ok, key, _source} <- ReqLLM.Keys.get(provider_atom, []) do
      {:ok, key}
    else
      _ -> {:error, "no API key stored and none found in the environment"}
    end
  end

  defp existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> {:error, :unknown}
  end
end
