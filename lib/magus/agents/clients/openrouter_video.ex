defmodule Magus.Agents.Clients.OpenRouterVideoBehaviour do
  @moduledoc """
  Behaviour for OpenRouter video generation, so the client can be mocked in tests.
  """

  @callback chat(messages :: list(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
end
