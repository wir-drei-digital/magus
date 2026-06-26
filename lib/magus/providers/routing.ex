defmodule Magus.Providers.Routing do
  @moduledoc """
  Builds OpenRouter provider routing maps based on model capabilities
  and user data region preferences.
  """

  alias Magus.Providers.Registry

  def build_provider_routing(model, user) do
    cond do
      model.api_provider != :openrouter ->
        nil

      is_nil(model.allowed_providers) or model.allowed_providers == [] ->
        %{"data_collection" => "deny"}

      true ->
        region_providers = Registry.providers_for_regions(user.data_region_preference)
        eligible = Enum.filter(model.allowed_providers, &(&1 in region_providers))
        %{"only" => eligible, "data_collection" => "deny"}
    end
  end

  def model_available_for_user?(model, user) do
    model_regions = Registry.regions_for_model(model)

    if model_regions == [] do
      true
    else
      Enum.any?(model_regions, &(&1 in user.data_region_preference))
    end
  end

  def missing_consent_regions(model, user) do
    model_regions = Registry.regions_for_model(model)
    consented = Map.keys(user.data_region_consents || %{})

    model_regions
    |> Enum.filter(&Registry.requires_consent?/1)
    |> Enum.reject(&(&1 in consented))
    |> Enum.sort()
  end
end
