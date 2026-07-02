defmodule Magus.Models.CredentialValidator do
  @moduledoc """
  Probes a provider's credentials with a minimal models-list request and
  returns a status. `validate/1` keeps the status-atom contract the Oban
  worker stamps; `probe/1` additionally returns the upstream model ids for
  the add-model picker. Tests and deployments can override the whole check
  via `config :magus, :credential_validator` (1-arity fun) and stub HTTP via
  `config :magus, :credential_probe_req_options`. The api_key is sent only
  as a request header (or the google `?key=` query param), never logged or
  returned.
  """

  @type status :: :valid | :invalid | :error

  @default_base_urls %{
    "openai" => "https://api.openai.com/v1",
    "openrouter" => "https://openrouter.ai/api/v1",
    "xai" => "https://api.x.ai/v1",
    "anthropic" => "https://api.anthropic.com/v1",
    "google" => "https://generativelanguage.googleapis.com/v1beta"
  }

  @spec validate(map()) :: status()
  def validate(provider) do
    case Application.get_env(:magus, :credential_validator) do
      fun when is_function(fun, 1) ->
        fun.(provider)

      _ ->
        case probe(provider) do
          {:valid, _ids} -> :valid
          other -> other
        end
    end
  end

  @spec probe(map()) :: {:valid, [String.t()]} | :invalid | :error
  def probe(provider) do
    case Application.get_env(:magus, :credential_probe) do
      fun when is_function(fun, 1) -> fun.(provider)
      _ -> do_probe(provider)
    end
  end

  defp do_probe(provider) do
    with {:ok, url, headers} <- request_for(provider) do
      opts =
        [url: url, headers: headers, receive_timeout: 5_000, retry: false] ++
          Application.get_env(:magus, :credential_probe_req_options, [])

      # Rescue broadly: a raised exception may embed the URL (which for google
      # carries the key). Never log it; collapse any failure to :error.
      try do
        case Req.get(opts) do
          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            {:valid, model_ids(provider.req_llm_id, body)}

          {:ok, %Req.Response{status: status}} when status in [401, 403] ->
            :invalid

          _ ->
            :error
        end
      rescue
        _ -> :error
      end
    end
  end

  defp request_for(%{req_llm_id: "anthropic", api_key: key}) do
    {:ok, "https://api.anthropic.com/v1/models",
     [{"x-api-key", key || ""}, {"anthropic-version", "2023-06-01"}]}
  end

  defp request_for(%{req_llm_id: "google", api_key: key}) do
    {:ok, "#{@default_base_urls["google"]}/models?key=#{key || ""}", []}
  end

  defp request_for(%{req_llm_id: id} = provider) do
    base = provider.base_url || Map.get(@default_base_urls, id)

    if is_binary(base) do
      {:ok, String.trim_trailing(base, "/") <> "/models",
       [{"authorization", "Bearer #{provider.api_key || ""}"}]}
    else
      :error
    end
  end

  # OpenAI-style: %{"data" => [%{"id" => ...}]}. Anthropic uses the same shape.
  # Google: %{"models" => [%{"name" => "models/gemini-..."}]}.
  defp model_ids("google", %{"models" => models}) when is_list(models) do
    models
    |> Enum.map(&(&1["name"] || ""))
    |> Enum.map(&String.replace_prefix(&1, "models/", ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp model_ids(_, %{"data" => data}) when is_list(data) do
    data |> Enum.map(& &1["id"]) |> Enum.filter(&is_binary/1)
  end

  defp model_ids(_, _), do: []
end
