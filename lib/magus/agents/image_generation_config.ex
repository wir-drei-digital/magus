defmodule Magus.Agents.ImageGenerationConfig do
  @moduledoc """
  Shared constants and validation for image generation settings.

  Used by both the UI (ModelSelectorComponent) and the API layer (OpenRouterImage).
  """

  @aspect_ratios ~w(1:1 2:3 3:2 3:4 4:3 4:5 5:4 9:16 16:9 21:9)
  @image_sizes ~w(1K 2K 4K)

  def aspect_ratios, do: @aspect_ratios
  def image_sizes, do: @image_sizes

  @doc """
  Validates and sanitizes an image generation settings map.
  Returns only recognized keys with allowed values, dropping anything invalid.
  """
  @spec sanitize(map() | nil) :: map()
  def sanitize(nil), do: %{}

  def sanitize(settings) when is_map(settings) do
    %{}
    |> maybe_put("aspect_ratio", settings["aspect_ratio"], @aspect_ratios)
    |> maybe_put("image_size", settings["image_size"], @image_sizes)
  end

  defp maybe_put(map, _key, nil, _allowed), do: map

  defp maybe_put(map, key, value, allowed) do
    if value in allowed, do: Map.put(map, key, value), else: map
  end
end
