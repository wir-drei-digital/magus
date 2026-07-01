defmodule Magus.Models.BaseUrlValidator do
  @moduledoc """
  Validates a user-supplied provider base URL to blunt SSRF: https only, no
  embedded credentials, and the resolved host must not fall in loopback,
  private, link-local, ULA, or cloud-metadata ranges. Admin providers are not
  routed through this (they may legitimately point at localhost).

  Limitation: DNS rebinding / TOCTOU is not fully closed by a static check
  plus validation-time resolution. A per-request egress guard is a later item.
  """

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" ->
        validate_host(host)

      %URI{userinfo: info} when not is_nil(info) ->
        {:error, "must not embed credentials"}

      %URI{scheme: "https"} ->
        {:error, "must include a host"}

      _ ->
        {:error, "must be an https URL"}
    end
  end

  def validate(_), do: {:error, "must be an https URL"}

  defp validate_host(host) do
    cond do
      host in ~w(localhost 0.0.0.0) -> {:error, "must not target a private host"}
      true -> validate_resolved(host)
    end
  end

  defp validate_resolved(host) do
    charlist = String.to_charlist(host)

    addrs =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, v4} -> v4
        _ -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, v6} -> v6
          _ -> []
        end

    cond do
      addrs == [] -> {:error, "host does not resolve"}
      Enum.any?(addrs, &blocked_ip?/1) -> {:error, "must not target a private host"}
      true -> :ok
    end
  end

  # IPv4 blocked ranges
  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({0, _, _, _}), do: true
  defp blocked_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # IPv6 loopback ::1
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 ULA fc00::/7 (first hextet high 7 bits == 1111110x)
  defp blocked_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  defp blocked_ip?(_), do: false
end
