defmodule Magus.Agents.Config do
  @moduledoc """
  Model configuration facade for agents.

  Every function delegates to `Magus.Models.Roles.resolve/1`, which applies
  the precedence: DB role assignment > legacy `config :magus, :agents` keys >
  DB default-model flags > code defaults > fallback roles.

  ## Configuration

  The legacy config keys remain honored for back-compat (a DB role assignment
  takes precedence when present):

      config :magus, :agents,
        default_model: "openrouter:openai/gpt-4o",
        summary_model: "openrouter:anthropic/claude-3.5-haiku",
        title_model: "openrouter:openai/gpt-4o",
        embedding_model: "openai/text-embedding-3-small"
  """

  @doc "Default model for general chat responses."
  def default_model, do: Magus.Models.Roles.resolve(:chat_default)

  @doc "Model for generating conversation summaries (should be fast/cheap)."
  def summary_model, do: Magus.Models.Roles.resolve(:summary)

  @doc "Model for generating conversation titles."
  def title_model, do: Magus.Models.Roles.resolve(:title_generation)

  @doc "Model for generating embeddings."
  def embedding_model, do: Magus.Models.Roles.resolve(:embeddings)

  @doc "Model for classifying message intent (should be fast/cheap, nil to disable)."
  def classification_model, do: Magus.Models.Roles.resolve(:intent_classification)

  @doc "Model for memory extraction (should be fast/cheap)."
  def extraction_model, do: Magus.Models.Roles.resolve(:memory_extraction)

  @doc """
  Whether the distilled user profile layer is enabled for the given user.
  Per-user opt-in (default false); there is no global env flag.
  """
  def profile_enabled?(user_id) when is_binary(user_id) do
    require Ash.Query

    Magus.Accounts.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.select([:profile_enabled])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{profile_enabled: true}} -> true
      _ -> false
    end
  end

  def profile_enabled?(_), do: false
end
