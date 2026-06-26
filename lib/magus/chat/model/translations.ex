defmodule Magus.Chat.Model.Translations do
  @moduledoc """
  Helper module for retrieving localized model descriptions.

  Provides functions to get the short and detailed descriptions in the
  user's preferred language with fallback to English and then to the
  original field value.
  """

  @doc """
  Gets the short description for a model in the current locale.

  Falls back through:
  1. Requested locale in translations map
  2. English ("en") in translations map
  3. Original short_description field (backward compatibility)

  ## Examples

      iex> Translations.short_description(model)
      "Flagship multimodal reasoning..."

      iex> Translations.short_description(model, "de")
      "Multimodales Flaggschiff-Modell..."
  """
  @spec short_description(map(), String.t() | nil) :: String.t() | nil
  def short_description(model, locale \\ nil)

  def short_description(model, locale) do
    get_translated_field(
      model,
      :short_description_translations,
      :short_description,
      locale
    )
  end

  @doc """
  Gets the detailed description for a model in the current locale.

  Falls back through:
  1. Requested locale in translations map
  2. English ("en") in translations map
  3. Original detailed_description field (backward compatibility)

  ## Examples

      iex> Translations.detailed_description(model)
      "Gemini 3 Pro Preview is designed for..."

      iex> Translations.detailed_description(model, "de")
      "Gemini 3 Pro Preview wurde für..."
  """
  @spec detailed_description(map(), String.t() | nil) :: String.t() | nil
  def detailed_description(model, locale \\ nil)

  def detailed_description(model, locale) do
    get_translated_field(
      model,
      :detailed_description_translations,
      :detailed_description,
      locale
    )
  end

  @doc """
  Gets all translation values from a translations map for search purposes.

  Returns a list of all values from the translations map.

  ## Examples

      iex> Translations.all_translation_values(%{"en" => "Hello", "de" => "Hallo"})
      ["Hello", "Hallo"]
  """
  @spec all_translation_values(map() | nil) :: [String.t()]
  def all_translation_values(nil), do: []
  def all_translation_values(translations) when is_map(translations), do: Map.values(translations)
  def all_translation_values(_), do: []

  # Private helpers

  defp get_translated_field(model, translations_field, fallback_field, locale) do
    locale = locale || get_current_locale()
    translations = Map.get(model, translations_field) || %{}

    cond do
      # Try requested locale first
      is_map(translations) and Map.has_key?(translations, locale) ->
        Map.get(translations, locale)

      # Fall back to English
      is_map(translations) and Map.has_key?(translations, "en") ->
        Map.get(translations, "en")

      # Fall back to original field for backward compatibility
      true ->
        Map.get(model, fallback_field)
    end
  end

  defp get_current_locale do
    case Gettext.get_locale(MagusWeb.Gettext) do
      nil -> "en"
      locale -> locale
    end
  end
end
