defmodule Magus.Models.Providers.OpenAICompatible do
  @moduledoc """
  Generic OpenAI-compatible ReqLLM provider for admin-configured custom
  endpoints (vLLM, llama.cpp server, LiteLLM, etc.).

  One shared provider id serves all custom endpoints: the per-request
  `base_url`/`api_key` come from the endpoint's Provider row via
  `Magus.Models.RequestOptions`, and models are passed as inline maps
  (`%{provider: :openai_compatible, id: "..."}`), so multiple custom
  endpoints coexist.
  """

  use ReqLLM.Provider,
    id: :openai_compatible,
    default_base_url: "http://localhost:8000/v1",
    default_env_key: "OPENAI_COMPATIBLE_API_KEY"
end
