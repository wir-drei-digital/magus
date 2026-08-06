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

  require Logger

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
    {model, opts} = provider_options(model, opts)
    ReqLLM.stream_text(model, context, opts)
  end

  @doc """
  Non-streaming text generation.

  Convenience wrapper that defaults opts to empty list.
  """
  def generate_text(model, context), do: generate_text(model, context, [])

  @impl true
  def generate_text(model, context, opts) do
    {model, opts} = provider_options(model, opts)
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
    {model, opts} = provider_options(model, opts)
    ReqLLM.generate_object(model, prompt, schema, opts)
  end

  @doc """
  Resolves DB-configured provider credentials/endpoints for the model key.

  Pops `:credential_actor_id` (the acting user) so owned-provider credentials
  are released only to their owner; the opt never reaches ReqLLM. Explicit
  opts win over resolved ones; non-binary model inputs pass through (with the
  opt still popped).
  """
  @spec provider_options(term(), keyword()) :: {term(), keyword()}
  def provider_options(model, opts) when is_binary(model) do
    {actor_id, opts} = Keyword.pop(opts, :credential_actor_id)
    opts = put_new_provider_routing(model, opts)
    {resolved_model, provider_opts} = Magus.Models.RequestOptions.resolve(model, actor_id)
    {resolved_model, Keyword.merge(provider_opts, opts)}
  end

  def provider_options(model, opts), do: {model, Keyword.delete(opts, :credential_actor_id)}

  # Every wrapped call gets the admin allow-list routing (magus-bcez):
  # background LLM calls (titles, extraction, summaries) previously hit
  # OpenRouter with no provider object at all. Preflight-computed routing in
  # the opts wins (put_new); a fully-denied model skips with a log here since
  # background calls have no user turn to attach an error to.
  defp put_new_provider_routing("openrouter:" <> _ = key, opts) do
    if Keyword.has_key?(opts, :openrouter_provider) do
      opts
    else
      case Magus.Providers.Routing.build_provider_routing_for_key(key) do
        %{} = routing ->
          Keyword.put(opts, :openrouter_provider, routing)

        {:error, :no_allowed_providers} ->
          Logger.warning(
            "OpenRouter routing: model #{inspect(key)} has no allowed providers; " <>
              "background call continuing unrouted"
          )

          opts

        nil ->
          opts
      end
    end
  end

  defp put_new_provider_routing(_key, opts), do: opts
end
