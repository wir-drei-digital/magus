defmodule Magus.Agents.VideoGenerationConfig do
  @moduledoc """
  Shared constants and validation for video generation settings.

  Used by both the UI (ModelSelectorComponent) and the API layer (AimlapiClient).
  """

  @aspect_ratios ~w(16:9 9:16 4:3 1:1 3:4 21:9 9:21)
  @durations ~w(2 3 4 5 6 8 10 12 16 20)
  @resolutions ~w(auto 480p 720p 1080p 4k)

  def aspect_ratios, do: @aspect_ratios
  def durations, do: @durations
  def resolutions, do: @resolutions

  @doc """
  Validates and sanitizes a video generation settings map.
  Returns only recognized keys with allowed values, dropping anything invalid.
  """
  @spec sanitize(map() | nil) :: map()
  def sanitize(nil), do: %{}

  def sanitize(settings) when is_map(settings) do
    %{}
    |> maybe_put("aspect_ratio", settings["aspect_ratio"], @aspect_ratios)
    |> maybe_put("duration", settings["duration"], @durations)
    |> maybe_put("resolution", settings["resolution"], @resolutions)
    |> maybe_put_boolean("generate_audio", settings["generate_audio"])
  end

  @doc """
  Converts a sanitized settings map into keyword opts for the AIML API client.
  """
  @spec to_keyword_opts(map() | nil) :: keyword()
  def to_keyword_opts(nil), do: []

  def to_keyword_opts(settings) when is_map(settings) do
    []
    |> maybe_add_opt(:aspect_ratio, settings["aspect_ratio"])
    |> maybe_add_opt(:duration, parse_integer(settings["duration"]))
    |> maybe_add_opt(:resolution, settings["resolution"])
    |> maybe_add_opt(:generate_audio, settings["generate_audio"])
  end

  defp maybe_put(map, _key, nil, _allowed), do: map

  defp maybe_put(map, key, value, allowed) do
    if value in allowed, do: Map.put(map, key, value), else: map
  end

  defp maybe_put_boolean(map, _key, nil), do: map

  defp maybe_put_boolean(map, key, value) when is_boolean(value),
    do: Map.put(map, key, value)

  defp maybe_put_boolean(map, key, "true"), do: Map.put(map, key, true)
  defp maybe_put_boolean(map, key, "false"), do: Map.put(map, key, false)
  defp maybe_put_boolean(map, _key, _value), do: map

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil
end
