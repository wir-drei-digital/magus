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
  Feature flag for the distilled user profile layer (Hermes-style working
  memory). Env var wins so eval A/B runs can toggle it per process.
  """
  def profile_enabled? do
    System.get_env("MAGUS_MEMORY_PROFILE") == "1" or
      Application.get_env(:magus, :memory_profile_enabled, false)
  end
end
