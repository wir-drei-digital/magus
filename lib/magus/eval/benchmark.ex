defmodule Magus.Eval.Benchmark do
  @moduledoc "Behaviour every eval benchmark implements. The core never names a specific benchmark."

  @type eval_case :: %{
          id: String.t(),
          ingest_items: [%{role: :user | :assistant, text: String.t()}],
          question: String.t(),
          gold: String.t(),
          meta: map()
        }

  @type result :: %{
          id: String.t(),
          question: String.t(),
          gold: String.t(),
          answer: String.t(),
          meta: map()
        }

  @callback name() :: String.t()
  @callback load_dataset(opts :: keyword) :: {:ok, term} | {:error, term}
  @callback cases(dataset :: term, opts :: keyword) :: [eval_case]
  @callback emit_hypotheses(results :: [result], path :: String.t()) :: :ok
  @callback score(results :: [result], opts :: keyword) :: %{aggregate: number, per_case: [map]}
end
