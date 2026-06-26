defmodule Magus.Agents.Tools.Integrations.SsrfValidator do
  @moduledoc """
  DNS-resolution-based SSRF protection for the HttpRequest tool.

  Validates URLs by resolving hostnames to IP addresses and rejecting
  private/reserved IP ranges to prevent Server-Side Request Forgery attacks.
  """

  import Bitwise

  @spec validate_url(String.t()) :: :ok | {:error, String.t()}
  def validate_url(url) when is_binary(url) and url != "" do
    with {:ok, parsed} <- parse_url(url),
         :ok <- validate_scheme(parsed),
         :ok <- validate_host(parsed.host) do
      :ok
    end
  end

  def validate_url(_), do: {:error, "Invalid URL"}

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        {:ok, %{scheme: scheme, host: host}}

      _ ->
        {:error, "Could not parse URL"}
    end
  end

  defp validate_scheme(%{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp validate_scheme(_), do: {:error, "Only HTTP and HTTPS schemes are allowed"}

  defp validate_host(host) do
    host_charlist = String.to_charlist(host)

    case :inet.getaddr(host_charlist, :inet) do
      {:ok, ip} ->
        if private_ip?(ip),
          do: {:error, "URL resolves to a private/reserved IP address"},
          else: :ok

      {:error, _} ->
        case :inet.getaddr(host_charlist, :inet6) do
          {:ok, ip6} ->
            if private_ipv6?(ip6),
              do: {:error, "URL resolves to a private/reserved IP address"},
              else: :ok

          {:error, _} ->
            {:error, "Could not resolve hostname: #{host}"}
        end
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?(_), do: false

  defp private_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ipv6?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp private_ipv6?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: true

  defp private_ipv6?({0, 0, 0, 0, 0, 0xFFFF, high, _low}) do
    a = high >>> 8
    b = high &&& 0xFF
    private_ip?({a, b, 0, 0})
  end

  defp private_ipv6?(_), do: false
end
