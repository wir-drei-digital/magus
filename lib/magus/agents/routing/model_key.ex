defmodule Magus.Agents.Routing.ModelKey do
  @moduledoc """
  Utilities for working with model keys.

  Model keys follow the format "provider:model_id", e.g., "openrouter:anthropic/claude-3.5-haiku".
  This module provides functions to parse and extract components from model keys.
  """

  @doc """
  Extracts the model ID from a model key.

  ## Examples

      iex> Magus.Agents.ModelKey.extract_model_id("openrouter:google/gemini-2.5-flash")
      "google/gemini-2.5-flash"

      iex> Magus.Agents.ModelKey.extract_model_id("google/gemini-2.5-flash")
      "google/gemini-2.5-flash"
  """
  @spec extract_model_id(String.t()) :: String.t()
  def extract_model_id(model_key) when is_binary(model_key) do
    case String.split(model_key, ":", parts: 2) do
      [_provider, model_id] -> model_id
      [model_id] -> model_id
    end
  end

  @doc """
  Extracts the provider from a model key.

  Returns the provider as an atom if it exists as an atom, otherwise as a string.
  Returns nil if no provider prefix is present.

  ## Examples

      iex> Magus.Agents.ModelKey.extract_provider("openrouter:google/gemini-2.5-flash")
      :openrouter

      iex> Magus.Agents.ModelKey.extract_provider("google/gemini-2.5-flash")
      nil
  """
  @spec extract_provider(String.t()) :: atom() | String.t() | nil
  def extract_provider(model_key) when is_binary(model_key) do
    case String.split(model_key, ":", parts: 2) do
      [provider, _model_id] ->
        try do
          String.to_existing_atom(provider)
        rescue
          ArgumentError -> provider
        end

      [_model_id] ->
        nil
    end
  end
end
