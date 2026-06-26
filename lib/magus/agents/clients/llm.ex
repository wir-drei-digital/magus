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

defmodule Magus.Agents.Clients.LLM do
  @moduledoc """
  Production LLM client wrapper implementing Magus.Agents.Clients.LLMBehaviour.

  This module wraps ReqLLM calls and implements the behaviour to enable
  dependency injection for testing.

  ## Configuration

  In production, this module is used directly. In tests, configure the mock:

      config :magus, :llm_client, Magus.Test.Mocks.LLMMock

  ## Usage

  Use the `llm_client/0` function to get the configured client at runtime:

      Magus.Agents.Clients.LLM.llm_client().stream_text(model, context, opts)
  """

  @behaviour Magus.Agents.Clients.LLMBehaviour

  @doc """
  Returns the configured LLM client module.

  In production, returns `Magus.Agents.Clients.LLM`.
  In tests, returns `Magus.Test.Mocks.LLMMock` (when configured).
  """
  def llm_client do
    Application.get_env(:magus, :llm_client, __MODULE__)
  end

  @impl true
  def stream_text(model, context, opts) do
    {model, opts} = with_provider_options(model, opts)
    ReqLLM.stream_text(model, context, opts)
  end

  @doc """
  Non-streaming text generation.

  Convenience wrapper that defaults opts to empty list.
  """
  def generate_text(model, context), do: generate_text(model, context, [])

  @impl true
  def generate_text(model, context, opts) do
    {model, opts} = with_provider_options(model, opts)
    ReqLLM.generate_text(model, context, opts)
  end

  @doc """
  One-shot, non-streaming completion from a plain text prompt.

  Wraps the prompt in a single user message, makes one `generate_text/3` call,
  and normalizes the ReqLLM response to `{:ok, %{text: text}}`. Used by
  `Magus.Eval.Judge` so callers do not need to know the ReqLLM context/response
  shape. Defaults opts to empty list.
  """
  def complete(model, prompt), do: complete(model, prompt, [])

  @spec complete(String.t(), String.t(), keyword()) ::
          {:ok, %{text: String.t()}} | {:error, term()}
  def complete(model, prompt, opts) when is_binary(prompt) do
    context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

    case generate_text(model, context, opts) do
      {:ok, response} -> {:ok, %{text: ReqLLM.Response.text(response) || ""}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Structured object generation with JSON schema.

  Convenience wrapper that defaults opts to empty list.
  """
  def generate_object(model, prompt, schema), do: generate_object(model, prompt, schema, [])

  @impl true
  def generate_object(model, prompt, schema, opts) do
    {model, opts} = with_provider_options(model, opts)
    ReqLLM.generate_object(model, prompt, schema, opts)
  end

  # Resolves DB-configured provider credentials/endpoints for the model key.
  # Explicit opts win over resolved ones; non-binary model inputs pass through.
  defp with_provider_options(model, opts) when is_binary(model) do
    {resolved_model, provider_opts} = Magus.Models.RequestOptions.resolve(model)
    {resolved_model, Keyword.merge(provider_opts, opts)}
  end

  defp with_provider_options(model, opts), do: {model, opts}
end
