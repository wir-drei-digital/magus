defmodule Magus.Integrations.Providers.ApiChannelBehaviour do
  @moduledoc """
  Behaviour for synchronous request/response channel integrations.
  The API channel implements this alongside ChannelBehaviour.
  """

  @doc "Parse an API request body and headers into a normalized map."
  @callback parse_request(params :: map(), headers :: list()) ::
              {:ok, map()} | {:error, term()}

  @doc "Whether this channel supports SSE streaming responses."
  @callback supports_streaming?() :: boolean()

  @doc """
  Return the list of event types to include for a given verbosity level.
  Verbosity: :minimal, :standard, :full
  """
  @callback stream_event_types(verbosity :: atom()) :: [String.t()]
end
