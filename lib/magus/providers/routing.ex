defmodule Magus.Providers.Routing do
  @moduledoc """
  Builds the OpenRouter `provider` routing map from the admin-managed provider
  allow-list minus each model's per-model denies. There is no region model:
  providers are either globally allowed or not, and a model may deny specific
  allowed providers.
  """

  require Logger

  @doc """
  Build the OpenRouter `provider` routing map for a model from the global
  admin allow-list minus the model's per-model denies. Returns `nil` for
  non-OpenRouter models, an error tuple when denies empty the list, and a
  bare `data_collection: deny` map (fail open) when nothing is allowed yet.
  """
  def build_provider_routing(%{api_provider: api_provider} = model)
      when api_provider in [:openrouter, "openrouter"] do
    allowed =
      Magus.Models.list_allowed_open_router_providers!(authorize?: false) |> Enum.map(& &1.slug)

    case allowed do
      [] ->
        Logger.warning(
          "OpenRouter routing: no providers allowed; routing unrestricted (data_collection: deny)"
        )

        %{"data_collection" => "deny"}

      _ ->
        denied = Map.get(model, :denied_providers) || []
        only = allowed -- denied

        if only == [] do
          {:error, :no_allowed_providers}
        else
          %{"only" => only, "data_collection" => "deny"}
        end
    end
  end

  def build_provider_routing(_model), do: nil
end
