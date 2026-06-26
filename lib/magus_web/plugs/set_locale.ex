defmodule MagusWeb.Plugs.SetLocale do
  @moduledoc """
  Plug to set the Gettext locale based on:
  1. URL query parameter (?lang=xx) - highest priority, also saves to session
  2. User preference (if authenticated)
  3. Session storage
  4. Accept-Language header from browser
  5. Default to "en"
  """
  import Plug.Conn

  @supported_locales ~w(en de)
  @default_locale "en"

  def init(opts), do: opts

  def call(conn, _opts) do
    {locale, save_to_session?} = determine_locale(conn)

    Gettext.put_locale(MagusWeb.Gettext, locale)

    conn = assign(conn, :locale, locale)

    if save_to_session? do
      put_session(conn, :locale, locale)
    else
      conn
    end
  end

  defp determine_locale(conn) do
    cond do
      # 1. Query parameter has highest priority and saves to session
      locale = get_locale_from_query(conn) ->
        {locale, true}

      # 2. User preference (authenticated users)
      locale = get_locale_from_user(conn) ->
        {locale, false}

      # 3. Session storage
      locale = get_locale_from_session(conn) ->
        {locale, false}

      # 4. Accept-Language header from browser
      locale = get_locale_from_header(conn) ->
        {locale, true}

      # 5. Default
      true ->
        {@default_locale, false}
    end
  end

  defp get_locale_from_query(conn) do
    locale = conn.query_params["lang"]
    if locale in @supported_locales, do: locale, else: nil
  end

  defp get_locale_from_user(conn) do
    case conn.assigns[:current_user] do
      %{language: language} when not is_nil(language) ->
        locale = to_string(language)
        if locale in @supported_locales, do: locale, else: nil

      _ ->
        nil
    end
  end

  defp get_locale_from_session(conn) do
    locale = get_session(conn, :locale)
    if locale in @supported_locales, do: locale, else: nil
  end

  defp get_locale_from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> parse_accept_language()
  end

  defp parse_accept_language([]), do: nil

  defp parse_accept_language([header | _]) do
    # Parse Accept-Language header, e.g., "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7"
    header
    |> String.split(",")
    |> Enum.map(&parse_language_tag/1)
    |> Enum.sort_by(fn {_lang, q} -> -q end)
    |> Enum.find_value(fn {lang, _q} ->
      # Try exact match first, then language prefix
      cond do
        lang in @supported_locales -> lang
        String.slice(lang, 0, 2) in @supported_locales -> String.slice(lang, 0, 2)
        true -> nil
      end
    end)
  end

  defp parse_language_tag(tag) do
    case String.split(String.trim(tag), ";") do
      [lang] ->
        {String.downcase(lang), 1.0}

      [lang, quality] ->
        q =
          case Regex.run(~r/q=([0-9.]+)/, quality) do
            [_, q_str] -> String.to_float(q_str)
            _ -> 1.0
          end

        {String.downcase(lang), q}
    end
  end

  @doc """
  Returns the preferred locale from Accept-Language header.
  Used for redirecting from / to /en/ or /de/.
  """
  def detect_browser_locale(conn) do
    get_locale_from_header(conn) || @default_locale
  end

  def supported_locales, do: @supported_locales
  def default_locale, do: @default_locale
end
