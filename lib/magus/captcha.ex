defmodule Magus.Captcha do
  @moduledoc """
  Captcha gate (Cloudflare Turnstile via phoenix_turnstile). Disabled unless
  BOTH :site_key and :secret_key are set (non-empty) in `config :magus,
  :captcha` — the library's own config defaults to Cloudflare's always-pass
  TEST keys, so enablement is decided exclusively here, never by the
  library. An empty string counts as unset: `System.get_env/1`-sourced
  runtime config (e.g. an unset Fly secret) yields `""`, not `nil`, and a
  bare `is_binary/1` check would silently "enable" captcha with an empty
  secret — locking out every signup.
  """

  def enabled? do
    config = config()
    configured?(config[:site_key]) and configured?(config[:secret_key])
  end

  @doc "The Turnstile site key from OUR config — never phoenix_turnstile's Cloudflare test-key default."
  def site_key, do: config()[:site_key]

  @doc "Called from Magus.Application.start/2. Half-config fails the boot."
  def validate_config! do
    config = config()
    site = config[:site_key]
    secret = config[:secret_key]

    cond do
      configured?(site) and configured?(secret) ->
        Application.put_env(:phoenix_turnstile, :site_key, site)
        Application.put_env(:phoenix_turnstile, :secret_key, secret)
        :ok

      not configured?(site) and not configured?(secret) ->
        :ok

      true ->
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

  defp configured?(value), do: is_binary(value) and value != ""

  defp impl, do: config()[:impl] || Turnstile
  defp config, do: Application.get_env(:magus, :captcha, [])
end
