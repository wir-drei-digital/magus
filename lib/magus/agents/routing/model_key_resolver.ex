defmodule Magus.Agents.Routing.ModelKeyResolver do
  @moduledoc """
  Resolves model keys for a conversation.

  Model key resolution follows this priority:
  1. Conversation-specific model selection
  2. User's default model preference
  3. `:auto` marker (triggers AutoRouter for all model types)

  This applies to all three model types: chat, image, and video.

  ## Usage

      {:ok, model_keys} = ModelKeyResolver.resolve(conversation)

  ## Parameters

  - `conversation` - A conversation struct with `:selected_model`, `:selected_image_model`,
    `:selected_video_model`, `custom_agent`, and `user` relationship loaded with the same fields.

  ## Returns

      {:ok, %{chat: "model-key" | :auto, image: "model-key" | :auto, video: "model-key" | :auto}}
  """

  alias Magus.Chat.Model

  @spec resolve(map()) :: {:ok, %{chat: String.t() | :auto, image: String.t(), video: String.t()}}
  def resolve(conversation) do
    agent = conversation.custom_agent

    model_keys = %{
      chat:
        resolve_chat_key(
          conversation.selected_model,
          agent_model(agent, :model),
          conversation.user.selected_model
        ),
      image:
        resolve_key(
          conversation.selected_image_model,
          agent_model(agent, :image_model),
          conversation.user.selected_image_model,
          :image
        ),
      video:
        resolve_key(
          conversation.selected_video_model,
          agent_model(agent, :video_model),
          conversation.user.selected_video_model,
          :video
        )
    }

    {:ok, model_keys}
  end

  @doc """
  Returns the system default model key for the given type.

  Used as fallback when no routing-eligible model matches.
  """
  def default_model_key(:chat) do
    # Magus.Config.default_model/0 is itself Roles.resolve(:chat_default), so
    # only the role resolution and a hardcoded last resort are meaningful here.
    Magus.Models.Roles.resolve(:chat_default) || "openrouter:anthropic/claude-sonnet-4"
  end

  def default_model_key(:image), do: Magus.Models.Roles.resolve(:image_default)
  def default_model_key(:video), do: Magus.Models.Roles.resolve(:video_t2v)

  # Extract model from custom agent (handles nil agent and unloaded relationships)
  defp agent_model(nil, _field), do: nil
  defp agent_model(%Ash.NotLoaded{}, _field), do: nil
  defp agent_model(agent, field), do: Map.get(agent, field)

  # Chat model: return :auto when no explicit selection exists
  # Priority: conversation > custom_agent > user > :auto
  defp resolve_chat_key(conv_model, agent_model, user_model) do
    cond do
      match?(%Model{key: _}, conv_model) -> conv_model.key
      match?(%Model{key: _}, agent_model) -> agent_model.key
      match?(%Model{key: _}, user_model) -> user_model.key
      true -> :auto
    end
  end

  # Image/video: return :auto when no explicit selection exists
  # Priority: conversation > custom_agent > user > :auto
  defp resolve_key(conv_model, agent_model, user_model, _type) do
    cond do
      match?(%Model{key: _}, conv_model) -> conv_model.key
      match?(%Model{key: _}, agent_model) -> agent_model.key
      match?(%Model{key: _}, user_model) -> user_model.key
      true -> :auto
    end
  end
end
