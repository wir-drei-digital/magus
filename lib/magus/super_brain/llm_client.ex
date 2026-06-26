defmodule Magus.SuperBrain.LLMClient do
  @moduledoc """
  Behaviour the SuperBrain extraction pipeline calls.

  Production binds to `Magus.SuperBrain.LLMClient.ReqLLM`, which delegates
  to the shared `Magus.Agents.Clients.LLM` wrapper around `ReqLLM`. Tests
  bind to a Mox mock (`Magus.SuperBrain.LLMMock`) so the extraction
  orchestrator can be exercised hermetically without hitting the network.

  ## Why a separate behaviour from `Magus.Agents.Clients.LLMBehaviour`?

  The SuperBrain extraction pipeline only needs a `complete/2` call that
  returns `%{content, usage}`. The agents-clients behaviour exposes
  the much richer `stream_text`/`generate_text`/`generate_object` surface
  that conversational agents need. Keeping them separate lets the
  extraction module evolve its own call shape (and usage-tracking concerns)
  without coupling to the agent runtime.
  """

  @callback complete(messages :: [map()], opts :: keyword()) ::
              {:ok,
               %{
                 content: String.t(),
                 usage: Magus.SuperBrain.Usage.t()
               }}
              | {:error, term()}
end
