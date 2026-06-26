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

defmodule Magus.Agents.Clients.VideoGen do
  @moduledoc """
  Production video generation client wrapper implementing Magus.Agents.Clients.VideoGenBehaviour.

  This module wraps AimlapiClient calls and implements the behaviour to enable
  dependency injection for testing.

  ## Configuration

  In production, this module is used directly. In tests, configure the mock:

      config :magus, :video_gen_client, Magus.Test.Mocks.VideoGenMock

  ## Usage

  Use the `video_gen_client/0` function to get the configured client at runtime:

      Magus.Agents.Clients.VideoGen.video_gen_client().chat(messages, opts)
  """

  @behaviour Magus.Agents.Clients.VideoGenBehaviour

  alias Magus.Agents.Providers.AimlapiClient

  @doc """
  Returns the configured video generation client module.

  In production, returns `Magus.Agents.Clients.VideoGen`.
  In tests, returns `Magus.Test.Mocks.VideoGenMock` (when configured).
  """
  def video_gen_client do
    Application.get_env(:magus, :video_gen_client, __MODULE__)
  end

  @impl true
  def chat(messages, opts \\ []) do
    AimlapiClient.chat(messages, opts)
  end
end
