defmodule Magus.Agents.Plugins.Support.ModelResolver do
  @moduledoc false
  # Resolves which LLM model to use for a conversation request.

  alias Magus.Agents.Routing.{ModelMatcher, ModelKeyResolver}

  @doc """
  Resolve the model to use for a conversation request.

  Priority: explicit `selected_model_id` > `model_keys` map entry for the
  given `mode` > fallback default model.
  """
  def resolve_model(model_keys, mode, selected_model_id, preloaded_models \\ [])

  def resolve_model(model_keys, mode, selected_model_id, preloaded_models)
      when is_binary(selected_model_id) do
    case Magus.Chat.get_model(selected_model_id) do
      {:ok, model} -> model
      _ -> resolve_from_keys(model_keys, mode, preloaded_models)
    end
  end

  def resolve_model(model_keys, mode, _selected_model_id, preloaded_models) do
    resolve_from_keys(model_keys, mode, preloaded_models)
  end

  # --- Private ---

  defp resolve_from_keys(model_keys, mode, preloaded_models) do
    case model_key_for_mode(model_keys, mode) do
      :auto -> resolve_auto_media(mode, preloaded_models)
      key when is_binary(key) -> find_or_fetch_model(key, preloaded_models)
      _ -> fallback_model()
    end
  end

  defp resolve_auto_media(mode, preloaded_models) do
    with specialty when not is_nil(specialty) <- media_specialty_for_mode(mode),
         {:ok, model_key} <- ModelMatcher.find_media_model(specialty) do
      fetch_or_fallback(model_key)
    else
      _ ->
        mode
        |> mode_to_key_type()
        |> ModelKeyResolver.default_model_key()
        |> find_or_fetch_model(preloaded_models)
    end
  end

  defp find_or_fetch_model(model_key, preloaded_models) do
    find_preloaded_model(preloaded_models, model_key) || fetch_or_fallback(model_key)
  end

  defp fetch_or_fallback(model_key) do
    case fetch_model_by_key(model_key) do
      {:ok, %{} = model} -> model
      _ -> fallback_model()
    end
  end

  # Model key extraction

  defp model_key_for_mode(%{} = keys, :image_generation), do: keys[:image] || keys[:chat]
  defp model_key_for_mode(%{} = keys, :video_generation), do: keys[:video] || keys[:chat]
  defp model_key_for_mode(%{} = keys, _mode), do: keys[:chat]
  defp model_key_for_mode(_, _), do: nil

  # Mode mapping

  defp media_specialty_for_mode(:image_generation), do: :image
  defp media_specialty_for_mode(:video_generation), do: :text_to_video
  defp media_specialty_for_mode(_), do: nil

  defp mode_to_key_type(:image_generation), do: :image
  defp mode_to_key_type(:video_generation), do: :video
  defp mode_to_key_type(_), do: :chat

  # Database lookups

  defp fetch_model_by_key(model_key) do
    require Ash.Query

    Magus.Chat.Model
    |> Ash.Query.filter(key == ^model_key)
    |> Ash.read_one(authorize?: false)
  end

  defp find_preloaded_model(preloaded_models, model_key)
       when is_list(preloaded_models) and is_binary(model_key) do
    Enum.find(preloaded_models, fn
      %{key: ^model_key} -> true
      %{"key" => ^model_key} -> true
      _ -> false
    end)
  end

  defp find_preloaded_model(_, _), do: nil

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
