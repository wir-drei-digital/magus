defmodule Magus.Providers.Registry do
  @moduledoc """
  Provides lookup functions for data regions and provider routing.
  Reads configuration from `config :magus, :data_regions`.
  """

  defp config, do: Application.get_env(:magus, :data_regions) || %{}

  def all_regions, do: config()[:regions] || %{}
  def default_allowed, do: config()[:default_allowed] || ["US", "EU", "CH"]

  def regions_requiring_consent do
    config()[:regions]
    |> Enum.filter(fn {_code, cfg} -> cfg.requires_consent end)
    |> Enum.map(fn {code, _cfg} -> code end)
  end

  def requires_consent?(region_code) do
    case region_config(region_code) do
      nil -> false
      cfg -> cfg.requires_consent
    end
  end

  def region_config(region_code) do
    Map.get(config()[:regions], region_code)
  end

  def region_for_provider(slug) do
    Map.get(config()[:providers], slug)
  end

  def providers_for_regions(regions) when is_list(regions) do
    config()[:providers]
    |> Enum.filter(fn {_slug, region} -> region in regions end)
    |> Enum.map(fn {slug, _region} -> slug end)
  end

  def regions_for_model(model) do
    providers = model.allowed_providers

    if is_list(providers) and providers != [] do
      providers
      |> Enum.map(&region_for_provider/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      case Map.get(config()[:api_provider_regions] || %{}, model.api_provider) do
        nil -> []
        region -> [region]
      end
    end
  end
end
