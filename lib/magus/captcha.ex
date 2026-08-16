defmodule Magus.Captcha do
  @moduledoc """
  Captcha gate (Cloudflare Turnstile via phoenix_turnstile). Disabled unless
  BOTH :site_key and :secret_key are set in `config :magus, :captcha` — the
  library's own config defaults to Cloudflare's always-pass TEST keys, so
  enablement is decided exclusively here, never by the library.
  """

  def enabled? do
    config = config()
    is_binary(config[:site_key]) and is_binary(config[:secret_key])
  end

  @doc "Called from Magus.Application.start/2. Half-config fails the boot."
  def validate_config! do
    config = config()

    case {config[:site_key], config[:secret_key]} do
      {site, secret} when is_binary(site) and is_binary(secret) ->
        Application.put_env(:phoenix_turnstile, :site_key, site)
        Application.put_env(:phoenix_turnstile, :secret_key, secret)
        :ok

      {nil, nil} ->
        :ok

      _ ->
        raise "captcha half-configured: set both TURNSTILE_SITE_KEY and " <>
                "TURNSTILE_SECRET_KEY, or neither (a missing secret would " <>
                "silently fall back to Cloudflare's always-pass test keys)"
    end
  end

  @spec verify(map(), :inet.ip_address() | nil) ::
          :ok | {:error, :missing_token | :invalid_token | :verification_unavailable}
  def verify(params, remote_ip) do
    cond do
      not enabled?() ->
        :ok

      not match?(%{"cf-turnstile-response" => t} when is_binary(t) and t != "", params) ->
        {:error, :missing_token}

      true ->
        case impl().verify(params, remote_ip) do
          {:ok, _body} -> :ok
          {:error, %{"success" => false}} -> {:error, :invalid_token}
          {:error, _transport_or_http} -> {:error, :verification_unavailable}
        end
    end
  end

  defp impl, do: config()[:impl] || Turnstile
  defp config, do: Application.get_env(:magus, :captcha, [])
end
