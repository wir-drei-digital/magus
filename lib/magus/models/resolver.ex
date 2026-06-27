defmodule Magus.Models.Resolver do
  @moduledoc """
  Central model resolution: turns a selection (explicit id/key, an auto-routed
  key, or an inherited default) into a `Magus.Models.Resolution`.

  Total: always returns `{:ok, %Resolution{}}`, producing the same model the
  legacy `Magus.Agents.Plugins.Support.ModelResolver` did. A broken explicit
  selection degrades to the inherited model (unchanged behavior) and is
  reported via `requested_selection` plus a
  `[:magus, :models, :resolution, :degraded]` telemetry event. Whether to
  hard-stop on a degradation is a caller policy, off in this phase.
  """

  require Ash.Query

  alias Magus.Agents.Routing.{ModelKeyResolver, ModelMatcher}
  alias Magus.Models.Resolution

  @spec resolve(term(), map()) :: {:ok, Resolution.t()}
  def resolve(_actor, %{model_keys: model_keys, mode: mode} = input) do
    selected_model_id = Map.get(input, :selected_model_id)
    preloaded = Map.get(input, :preloaded, [])
    auto_routed = Map.get(input, :auto_routed)

    resolution =
      model_keys
      |> build(mode, selected_model_id, preloaded, auto_routed)
      |> emit_degraded_telemetry(mode)

    {:ok, resolution}
  end

  # Explicit by id: found -> :explicit. Miss -> fall through to the keys map,
  # carrying the original ask so the degradation is visible.
  defp build(model_keys, mode, selected_model_id, preloaded, auto_routed)
       when is_binary(selected_model_id) do
    case Magus.Chat.get_model(selected_model_id) do
      {:ok, model} ->
        resolution(model, :explicit, %{by: :id, value: selected_model_id})

      _ ->
        from_keys(model_keys, mode, preloaded, auto_routed, %{by: :id, value: selected_model_id})
    end
  end

  defp build(model_keys, mode, _selected_model_id, preloaded, auto_routed) do
    from_keys(model_keys, mode, preloaded, auto_routed, nil)
  end

  defp from_keys(model_keys, mode, preloaded, auto_routed, inherited_requested) do
    case model_key_for_mode(model_keys, mode) do
      :auto ->
        {model, source} = resolve_auto(mode, preloaded)
        resolution(model, source, inherited_requested)

      key when is_binary(key) ->
        {model, source, key_requested} = from_key(key, preloaded, mode, auto_routed)
        resolution(model, source, inherited_requested || key_requested)

      _ ->
        resolution(fallback_model(), :product_default, inherited_requested)
    end
  end

  # A concrete key. Auto-routed (per caller provenance) -> :auto, no ask
  # recorded. Otherwise an explicit ask: :explicit on hit, :product_default on
  # miss (synthetic fallback), with the ask recorded either way.
  defp from_key(key, preloaded, mode, auto_routed) do
    if auto_routed?(auto_routed, mode) do
      {find_or_fetch(key, preloaded), :auto, nil}
    else
      model = find_or_fetch(key, preloaded)
      source = if model.key == key, do: :explicit, else: :product_default
      {model, source, %{by: :key, value: key}}
    end
  end

  # Mirrors ModelResolver.resolve_auto_media: media specialty match (no
  # preloaded lookup) -> :auto; otherwise the role default for the mode's key
  # type (with preloaded lookup) -> :role_default.
  defp resolve_auto(mode, preloaded) do
    with specialty when not is_nil(specialty) <- media_specialty_for_mode(mode),
         {:ok, key} <- ModelMatcher.find_media_model(specialty) do
      {fetch_or_fallback(key), :auto}
    else
      _ ->
        key = ModelKeyResolver.default_model_key(mode_to_key_type(mode))
        {find_or_fetch(key, preloaded), :role_default}
    end
  end

  defp resolution(model, selection_source, requested) do
    %Resolution{
      model: model,
      selection_source: selection_source,
      requested_selection: requested,
      provider_id: provider_id(model),
      access_source: :global,
      credential_owner_user_id: nil,
      cost_source: :platform_key
    }
  end

  defp emit_degraded_telemetry(%Resolution{} = resolution, mode) do
    if Resolution.degraded?(resolution) do
      :telemetry.execute(
        [:magus, :models, :resolution, :degraded],
        %{count: 1},
        %{
          requested: resolution.requested_selection,
          selection_source: resolution.selection_source,
          mode: mode
        }
      )
    end

    resolution
  end

  # --- key/mode helpers (ported verbatim from ModelResolver) ---

  defp model_key_for_mode(%{} = keys, :image_generation), do: keys[:image] || keys[:chat]
  defp model_key_for_mode(%{} = keys, :video_generation), do: keys[:video] || keys[:chat]
  defp model_key_for_mode(%{} = keys, _mode), do: keys[:chat]
  defp model_key_for_mode(_, _), do: nil

  defp media_specialty_for_mode(:image_generation), do: :image
  defp media_specialty_for_mode(:video_generation), do: :text_to_video
  defp media_specialty_for_mode(_), do: nil

  defp mode_to_key_type(:image_generation), do: :image
  defp mode_to_key_type(:video_generation), do: :video
  defp mode_to_key_type(_), do: :chat

  defp auto_routed?(nil, _mode), do: false
  defp auto_routed?(%{} = map, mode), do: Map.get(map, mode_to_key_type(mode), false) == true

  defp find_or_fetch(key, preloaded), do: find_preloaded(preloaded, key) || fetch_or_fallback(key)

  defp fetch_or_fallback(key), do: fetch_by_key(key) || fallback_model()

  defp fetch_by_key(key) when is_binary(key) do
    case Magus.Chat.Model |> Ash.Query.filter(key == ^key) |> Ash.read_one(authorize?: false) do
      {:ok, %{} = model} -> model
      _ -> nil
    end
  end

  defp find_preloaded(preloaded, key) when is_list(preloaded) and is_binary(key) do
    Enum.find(preloaded, fn
      %{key: ^key} -> true
      %{"key" => ^key} -> true
      _ -> false
    end)
  end

  defp find_preloaded(_, _), do: nil

  defp provider_id(%{model_provider_id: id}), do: id
  defp provider_id(_), do: nil

  defp fallback_model do
    %Magus.Chat.Model{
      key: Magus.Agents.Config.default_model(),
      name: "Default",
      context_window: 128_000,
      input_cost: "0",
      output_cost: "0",
      supports_tools?: true
    }
  end
end
