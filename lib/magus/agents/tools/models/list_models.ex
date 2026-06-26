defmodule Magus.Agents.Tools.Models.ListModels do
  @moduledoc """
  Lists available AI models with their capabilities, descriptions, and cost info.
  Supports different modes: "all" returns every eligible model, "council" returns
  one best model per whitelisted provider for diverse multi-agent panels.
  """

  use Jido.Action,
    name: "list_models",
    description: """
    List available AI models with their capabilities and descriptions.
    Use this to find the best model for a specific task before spawning a sub-agent.

    Modes:
    - "all" (default): Returns all eligible models. Use filters to narrow down.
    - "council": Returns one top model per provider from major providers (Anthropic, Google, OpenAI, xAI, etc.)
      for spawning diverse sub-agent panels. Automatically filters to tool-capable text models.

    Returns model key, description, capabilities, context window, and cost.
    """,
    schema: [
      mode: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Listing mode: \"all\" (default) or \"council\" (one best model per provider)"
      ],
      supports_tools: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "Filter to models that support tool/function calling"
      ],
      supports_search: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "Filter to models that support web search"
      ],
      supports_reasoning: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "Filter to models that support extended reasoning"
      ],
      output_modality: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Filter by output modality (e.g. \"text\", \"image\", \"video\")"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @council_providers MapSet.new([
                       "Anthropic",
                       "Google",
                       "Swiss AI",
                       "OpenAI",
                       "xAI",
                       "Mistral AI"
                     ])

  def display_name, do: "Listing available models..."

  def summarize_output(%{models: models}), do: "Found #{length(models)} models"
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, _context) do
    # Model listing is not user-scoped (model access is ungated), so no
    # context keys are required.
    list_models(params)
  end

  defp list_models(params) do
    case Magus.Chat.list_active_models(authorize?: false) do
      {:ok, models} ->
        eligible =
          models
          |> apply_mode(params)
          |> apply_filters(params)
          |> Enum.map(&format_model/1)
          |> Enum.sort_by(& &1.provider)

        {:ok, %{models: eligible}}

      {:error, reason} ->
        {:ok, %{error: "Failed to load models: #{inspect(reason)}"}}
    end
  end

  # Council mode: filter to tool-capable text models from whitelisted providers,
  # then pick one model per provider for a diverse panel.
  defp apply_mode(models, params) do
    case get_param(params, :mode) do
      "council" ->
        models
        |> Enum.filter(fn model ->
          model.supports_tools? &&
            "text" in (model.output_modalities || []) &&
            MapSet.member?(@council_providers, model.provider)
        end)
        |> pick_one_per_provider()

      _ ->
        models
    end
  end

  defp apply_filters(models, params) do
    models
    |> maybe_filter(:supports_tools?, get_param(params, :supports_tools))
    |> maybe_filter(:supports_search?, get_param(params, :supports_search))
    |> maybe_filter(:supports_reasoning?, get_param(params, :supports_reasoning))
    |> maybe_filter_modality(get_param(params, :output_modality))
  end

  defp maybe_filter(models, _field, nil), do: models

  defp maybe_filter(models, field, value) do
    Enum.filter(models, fn model -> Map.get(model, field) == value end)
  end

  defp maybe_filter_modality(models, nil), do: models

  defp maybe_filter_modality(models, modality) do
    Enum.filter(models, fn model ->
      modality in (model.output_modalities || [])
    end)
  end

  defp format_model(model) do
    %{
      key: model.key,
      name: model.name,
      provider: format_provider(model),
      short_description: model.short_description,
      capabilities: %{
        supports_tools: model.supports_tools? || false,
        supports_search: model.supports_search? || false,
        supports_reasoning: model.supports_reasoning? || false
      },
      input_modalities: model.input_modalities || [],
      output_modalities: model.output_modalities || [],
      context_window: model.context_window,
      input_cost: model.input_cost,
      output_cost: model.output_cost
    }
  end

  defp format_provider(%{provider: provider}) when is_binary(provider) and provider != "",
    do: provider

  defp format_provider(%{key: key}) when is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [provider, _model_id] when provider != "" -> provider
      _ -> "Unknown"
    end
  end

  defp format_provider(_model), do: "Unknown"

  # Pick one model per provider for a diverse panel. Sorting is handled by the
  # caller in the main pipeline; within a provider we pick deterministically by
  # name so the council is stable across calls.
  defp pick_one_per_provider(models) do
    models
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {_provider, provider_models} ->
      Enum.min_by(provider_models, & &1.name)
    end)
  end
end
