defmodule Magus.Knowledge.Connectors.Web.Boundary do
  @moduledoc """
  URL normalization and boundary rule checking for web knowledge connectors.

  Used by all discovery strategies (sitemap, OpenAPI, pagination, link-following)
  to normalize URLs for deduplication and enforce crawl boundaries.
  """

  @tracking_params ~w(ref source fbclid gclid)

  @blocked_extensions ~w(
    .zip .exe .tar .gz .bz2 .7z .rar
    .mp4 .mp3 .avi .mov .wmv .flv .webm .ogg
    .png .jpg .jpeg .gif .svg .ico .webp .bmp .tiff
    .css .js .woff .woff2 .ttf .eot
    .pdf .doc .docx .xls .xlsx .ppt .pptx
    .dmg .pkg .deb .rpm .apk .ipa
  )

  @doc """
  Returns a canonical form of the given URL for deduplication.

  Transformations applied:
  - Lowercases scheme and host
  - Removes default ports (80 for http, 443 for https)
  - Removes URL fragments (#...)
  - Strips tracking query params (utm_*, ref, source, fbclid, gclid)
  - Strips trailing slash from non-root paths

  Returns the original URL string unchanged if it cannot be parsed.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        uri
        |> normalize_scheme_and_host()
        |> remove_default_port()
        |> remove_fragment()
        |> strip_tracking_params()
        |> normalize_trailing_slash()
        |> URI.to_string()

      _ ->
        url
    end
  end

  @doc """
  Returns `true` if `url` is permitted by the given config, robots rules, and depth.

  Checks performed in order:
  1. Scheme must be http or https
  2. Host must be in `allowed_domains`
  3. Path must match an `allowed_paths` prefix (if list is non-empty)
  4. Path must not match any `excluded_paths` prefix
  5. `depth` must be <= `max_depth`
  6. File extension must not be in the blocked list
  7. If `respect_robots_txt` is true, path must not match any disallow rule

  Returns `false` for any unparseable URL.
  """
  @spec allowed?(String.t(), map(), list(map()), non_neg_integer()) :: boolean()
  def allowed?(url, config, robots_rules, depth) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} when is_binary(scheme) and is_binary(host) ->
        normalized_path = path || "/"

        check_scheme(scheme) &&
          check_domain(host, config) &&
          check_allowed_paths(normalized_path, config) &&
          check_excluded_paths(normalized_path, config) &&
          check_depth(depth, config) &&
          check_extension(normalized_path) &&
          check_robots(normalized_path, config, robots_rules)

      _ ->
        false
    end
  end

  # --- normalize/1 helpers ---

  defp normalize_scheme_and_host(%URI{scheme: scheme, host: host} = uri) do
    %URI{
      uri
      | scheme: scheme && String.downcase(scheme),
        host: host && String.downcase(host)
    }
  end

  defp remove_default_port(%URI{scheme: "https", port: 443} = uri), do: %URI{uri | port: nil}
  defp remove_default_port(%URI{scheme: "http", port: 80} = uri), do: %URI{uri | port: nil}
  defp remove_default_port(uri), do: uri

  defp remove_fragment(%URI{} = uri), do: %URI{uri | fragment: nil}

  defp strip_tracking_params(%URI{query: nil} = uri), do: uri

  defp strip_tracking_params(%URI{query: query} = uri) do
    filtered =
      query
      |> URI.decode_query()
      |> Enum.reject(fn {key, _value} ->
        String.starts_with?(key, "utm_") or key in @tracking_params
      end)
      |> case do
        [] -> nil
        pairs -> URI.encode_query(pairs)
      end

    %URI{uri | query: filtered}
  end

  defp normalize_trailing_slash(%URI{path: nil} = uri), do: uri
  defp normalize_trailing_slash(%URI{path: "/"} = uri), do: uri

  defp normalize_trailing_slash(%URI{path: path} = uri) do
    %URI{uri | path: String.trim_trailing(path, "/")}
  end

  # --- allowed?/4 helpers ---

  defp check_scheme(scheme), do: scheme in ["http", "https"]

  defp check_domain(host, %{"allowed_domains" => domains}) when is_list(domains) do
    host in domains
  end

  defp check_domain(_host, _config), do: false

  defp check_allowed_paths(_path, %{"allowed_paths" => []}), do: true

  defp check_allowed_paths(path, %{"allowed_paths" => prefixes}) when is_list(prefixes) do
    Enum.any?(prefixes, &String.starts_with?(path, &1))
  end

  defp check_allowed_paths(_path, _config), do: true

  defp check_excluded_paths(_path, %{"excluded_paths" => []}), do: true

  defp check_excluded_paths(path, %{"excluded_paths" => prefixes}) when is_list(prefixes) do
    not Enum.any?(prefixes, &String.starts_with?(path, &1))
  end

  defp check_excluded_paths(_path, _config), do: true

  defp check_depth(depth, %{"max_depth" => max_depth}) when is_integer(max_depth) do
    depth <= max_depth
  end

  defp check_depth(_depth, _config), do: true

  defp check_extension(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext == "" or ext not in @blocked_extensions
  end

  defp check_robots(_path, %{"respect_robots_txt" => false}, _rules), do: true
  defp check_robots(_path, %{"respect_robots_txt" => nil}, _rules), do: true
  defp check_robots(_path, _config_without_key, []), do: true

  defp check_robots(path, %{"respect_robots_txt" => true}, robots_rules) do
    disallow_paths =
      robots_rules
      |> Enum.filter(fn %{user_agent: ua} -> ua == "*" end)
      |> Enum.flat_map(fn %{disallow: disallows} -> disallows end)

    not Enum.any?(disallow_paths, &String.starts_with?(path, &1))
  end

  defp check_robots(_path, _config, _rules), do: true
end
