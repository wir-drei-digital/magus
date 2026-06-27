defmodule Magus.Agents.Clients.ImageGenBehaviour do
  @moduledoc """
  Behaviour for image generation client operations.

  This allows mocking image generation calls in tests.
  """

  @doc "Generate images from a model key and conversation context"
  @callback generate_image(
              model_key :: String.t() | nil,
              context :: list(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
end
