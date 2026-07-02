defmodule Magus.Models.Resolver do
  @moduledoc """
  Central model resolution: turns a selection (explicit id/key, an auto-routed
  key, or an inherited default) into a `Magus.Models.Resolution`.

  Total: always returns `{:ok, %Resolution{}}`, producing the same model the
  legacy resolver did. A broken explicit selection degrades to the inherited
  model (unchanged behavior) and is
  reported via `requested_selection` plus a
  `[:magus, :models, :resolution, :degraded]` telemetry event. Whether to
  hard-stop on a degradation is a caller policy, off in this phase.
  """

  require Ash.Query

  alias Magus.Agents.Routing.{ModelKeyResolver, ModelMatcher}
  alias Magus.Models.Resolution

  @spec resolve(term(), map()) :: {:ok, Resolution.t()}
  def resolve(actor, %{model_keys: model_keys, mode: mode} = input) do
    actor_id = actor_id(actor)
    selected_model_id = Map.get(input, :selected_model_id)
    preloaded = Map.get(input, :preloaded, [])
    auto_routed = Map.get(input, :auto_routed)

    resolution =
      model_keys
      |> build(mode, selected_model_id, preloaded, auto_routed, actor_id)
      |> emit_degraded_telemetry(mode)

    {:ok, resolution}
  end

  # An actor scopes owned-model visibility. A nil actor sees global rows only
  # (owned rows are excluded, fail-closed). Accepts a user struct/map with a
  # binary :id, or a bare binary id (the form Preflight/MediaBypass thread).
  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_), do: nil

  # Explicit by id: found -> :explicit. Miss -> fall through to the keys map,
  # carrying the original ask so the degradation is visible.
  defp build(model_keys, mode, selected_model_id, preloaded, auto_routed, actor_id)
       when is_binary(selected_model_id) do
    case get_owned_or_global_model(selected_model_id, actor_id) do
      {:ok, model} ->
        resolution(model, :explicit, %{by: :id, value: selected_model_id})

      _ ->
        from_keys(
          model_keys,
          mode,
          preloaded,
          auto_routed,
          %{by: :id, value: selected_model_id},
          actor_id
        )
    end
  end

  defp build(model_keys, mode, _selected_model_id, preloaded, auto_routed, actor_id) do
    from_keys(model_keys, mode, preloaded, auto_routed, nil, actor_id)
  end

  defp from_keys(model_keys, mode, preloaded, auto_routed, inherited_requested, actor_id) do
    case model_key_for_mode(model_keys, mode) do
      :auto ->
        {model, source} = resolve_auto(mode, preloaded, actor_id)
        resolution(model, source, inherited_requested)

      key when is_binary(key) ->
        {model, source, key_requested} = from_key(key, preloaded, mode, auto_routed, actor_id)
        resolution(model, source, inherited_requested || key_requested)

      _ ->
        resolution(fallback_model(), :product_default, inherited_requested)
    end
  end

  # A concrete key. Auto-routed (per caller provenance) -> :auto, no ask
  # recorded. Otherwise an explicit ask: :explicit on hit, :product_default on
  # miss (synthetic fallback), with the ask recorded either way.
  defp from_key(key, preloaded, mode, auto_routed, actor_id) do
    if auto_routed?(auto_routed, mode) do
      {find_or_fetch(key, preloaded, actor_id), :auto, nil}
    else
      model = find_or_fetch(key, preloaded, actor_id)
      source = if model.key == key, do: :explicit, else: :product_default
      {model, source, %{by: :key, value: key}}
    end
  end

  # Media :auto resolution: media specialty match (no
  # preloaded lookup) -> :auto; otherwise the role default for the mode's key
  # type (with preloaded lookup) -> :role_default.
  defp resolve_auto(mode, preloaded, actor_id) do
    with specialty when not is_nil(specialty) <- media_specialty_for_mode(mode),
         {:ok, key} <- ModelMatcher.find_media_model(specialty) do
      {fetch_or_fallback(key, actor_id), :auto}
    else
      _ ->
        key = ModelKeyResolver.default_model_key(mode_to_key_type(mode))
        {find_or_fetch(key, preloaded, actor_id), :role_default}
    end
  end

  defp resolution(model, selection_source, requested) do
    %Resolution{
      model: model,
      selection_source: selection_source,
      requested_selection: requested,
      provider_id: provider_id(model),
      access_source: access_source(model),
      credential_owner_user_id: owner_of(model),
      cost_source: cost_source(model)
    }
  end

  defp access_source(%{owner_user_id: owner}) when is_binary(owner), do: :owned
  defp access_source(_), do: :global

  defp owner_of(%{owner_user_id: owner}) when is_binary(owner), do: owner
  defp owner_of(_), do: nil

  defp cost_source(%{owner_user_id: owner}) when is_binary(owner), do: :byok
  defp cost_source(_), do: :platform_key

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

  # --- key/mode helpers ---

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

  defp find_or_fetch(key, preloaded, actor_id),
    do: find_preloaded(preloaded, key) || fetch_or_fallback(key, actor_id)

  defp fetch_or_fallback(key, actor_id), do: fetch_by_key(key, actor_id) || fallback_model()

  # read_one returns {:ok, nil} on a miss; collapse that to :error so the
  # explicit-id path falls through to the keys map (a real match returns
  # {:ok, model}).
  defp get_owned_or_global_model(id, actor_id) when is_binary(id) do
    case Magus.Chat.Model
         |> Ash.Query.filter(id == ^id)
         |> scope_owner(actor_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = model} -> {:ok, model}
      _ -> :error
    end
  end

  defp fetch_by_key(key, actor_id) when is_binary(key) do
    case Magus.Chat.Model
         |> Ash.Query.filter(key == ^key)
         |> scope_owner(actor_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = model} -> model
      _ -> nil
    end
  end

  # Scope owned-model visibility. A binary actor sees global rows plus their own
  # owned rows. A nil actor sees global rows only; branching here avoids the
  # `owner_user_id == nil` comparison Ash warns about (always false).
  defp scope_owner(query, actor_id) when is_binary(actor_id),
    do: Ash.Query.filter(query, is_nil(owner_user_id) or owner_user_id == ^actor_id)

  defp scope_owner(query, _actor_id),
    do: Ash.Query.filter(query, is_nil(owner_user_id))

  defp find_preloaded(preloaded, key) when is_list(preloaded) and is_binary(key) do
    Enum.find(preloaded, fn
      %{key: ^key} -> true
      %{"key" => ^key} -> true
      _ -> false
    end)
  end

  defp find_preloaded(_, _), do: nil

  defp provider_id(%{model_provider_id: id}) when is_binary(id), do: id
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
