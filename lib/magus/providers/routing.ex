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
        # is_list guard: a select-limited model would carry %Ash.NotLoaded{}
        # (truthy), and list subtraction on it raises.
        denied =
          case Map.get(model, :denied_providers) do
            denied when is_list(denied) -> denied
            _ -> []
          end

        only = allowed -- denied

        if only == [] do
          {:error, :no_allowed_providers}
        else
          %{"only" => only, "data_collection" => "deny"}
        end
    end
  end

  def build_provider_routing(_model), do: nil

  @doc """
  Key-based variant for call sites without a loaded `%Model{}` (background
  LLM calls: title generation, extraction, summaries). Looks up the catalog
  row so per-model denies apply; an unregistered `openrouter:` key still gets
  allow-list-only routing. Returns `nil` for non-OpenRouter keys.
  """
  def build_provider_routing_for_key("openrouter:" <> _ = key) do
    case fetch_model_by_key(key) do
      %{} = model -> build_provider_routing(model)
      nil -> build_provider_routing(%{api_provider: :openrouter, denied_providers: []})
    end
  end

  def build_provider_routing_for_key(_key), do: nil

  defp fetch_model_by_key(key) do
    require Ash.Query

    case Magus.Chat.Model
         |> Ash.Query.filter(key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = model} -> model
      _ -> nil
    end
  end
end
