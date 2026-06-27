defmodule Magus.Agents.Clients.LLMBehaviour do
  @moduledoc """
  Behaviour for LLM client operations.

  This allows mocking ReqLLM calls in tests.
  """

  @doc "Streaming text generation"
  @callback stream_text(model :: String.t(), context :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Non-streaming text generation"
  @callback generate_text(model :: String.t(), context :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Structured object generation with JSON schema"
  @callback generate_object(
              model :: String.t(),
              prompt :: String.t(),
              schema :: term(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:error, term()}
end
