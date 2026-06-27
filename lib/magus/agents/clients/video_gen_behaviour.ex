defmodule Magus.Agents.Clients.VideoGenBehaviour do
  @moduledoc """
  Behaviour for video generation client operations.

  This allows mocking video generation calls in tests.
  """

  @doc "Generate videos from messages context (chat interface)"
  @callback chat(
              messages :: list(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
end
