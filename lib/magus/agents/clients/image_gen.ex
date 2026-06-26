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

defmodule Magus.Agents.Clients.ImageGen do
  @moduledoc """
  Production image generation client wrapper implementing Magus.Agents.Clients.ImageGenBehaviour.

  This module wraps OpenRouterImage calls and implements the behaviour to enable
  dependency injection for testing.

  ## Configuration

  In production, this module is used directly. In tests, configure the mock:

      config :magus, :image_gen_client, Magus.Test.Mocks.ImageGenMock

  ## Usage

  Use the `image_gen_client/0` function to get the configured client at runtime:

      Magus.Agents.Clients.ImageGen.image_gen_client().generate_image(model_key, context, opts)
  """

  @behaviour Magus.Agents.Clients.ImageGenBehaviour

  alias Magus.Agents.Providers.OpenRouterImage

  @doc """
  Returns the configured image generation client module.

  In production, returns `Magus.Agents.Clients.ImageGen`.
  In tests, returns `Magus.Test.Mocks.ImageGenMock` (when configured).
  """
  def image_gen_client do
    Application.get_env(:magus, :image_gen_client, __MODULE__)
  end

  @impl true
  def generate_image(model_key, context, opts \\ []) do
    OpenRouterImage.generate_image(model_key, context, opts)
  end
end
