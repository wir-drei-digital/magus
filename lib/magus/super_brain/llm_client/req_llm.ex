defmodule Magus.SuperBrain.LLMClient.ReqLLM do
  @moduledoc """
  Production adapter for `Magus.SuperBrain.LLMClient`.

  Delegates to the shared `Magus.Agents.Clients.LLM.generate_object/4`
  wrapper around ReqLLM. Using structured-output (rather than free-form
  text) means the provider validates the model's response against the
  extraction schema, so the orchestrator never has to defensively parse
  fenced or prose-wrapped JSON. The configured model MUST support
  tool/function calling (ReqLLM's OpenRouter provider implements
  structured output via a `structured_output` tool by default).

  The provider-validated object is re-encoded as JSON so this adapter keeps
  the `complete/2` contract returning `%{content, usage}`; the extraction
  orchestrator then decodes + business-rule-sanitizes it exactly as it does
  for the test mock.

  ## Usage reporting

  ReqLLM exposes a `usage` map (input/output tokens) on the response
  struct. This adapter reads those token counts and looks up the model's
  per-million-token pricing via `Magus.Chat.get_model_by_name/1` to compute
  `input_cost`/`output_cost`/`total_cost` as `Decimal` dollar amounts.

  When the model is not registered in the catalog (or has no pricing
  fields populated), costs fall through to `Decimal.new("0")` so the
  caller still gets a populated `Usage` struct with token counts.
  """

  @behaviour Magus.SuperBrain.LLMClient

  alias Magus.Agents.Clients.LLM

  @impl true
  def complete(messages, opts) when is_list(messages) and is_list(opts) do
    model = Keyword.get(opts, :model) || Magus.Models.Roles.resolve(:super_brain_extraction)

    context_messages =
      Enum.map(messages, fn
        %{role: "system", content: c} -> ReqLLM.Context.system(c)
        %{role: "user", content: c} -> ReqLLM.Context.user(c)
        %{role: "assistant", content: c} -> ReqLLM.Context.assistant(c)
      end)

    context = ReqLLM.Context.new(context_messages)

    case LLM.llm_client().generate_object(model, context, extraction_schema(), []) do
      {:ok, %ReqLLM.Response{} = response} ->
        case ReqLLM.Response.object(response) do
          nil ->
            # The model returned no structured output (e.g. refused, or the
            # endpoint silently dropped the tool call). Surface as an error so
            # the worker fails and Oban retries rather than persisting nothing.
            {:error, :no_structured_output}

          object ->
            usage = build_usage(response, model)
            {:ok, %{content: Jason.encode!(object), usage: usage}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Structured-output schema for `generate_object/4`. ReqLLM converts this to
  # the provider's tool / JSON-schema, so the model returns a validated object
  # instead of free-form text. `subtype` is optional: the model omits it when
  # no finer granularity applies. Business rules (confidence floor, ontology
  # coercion, name clipping, edge-endpoint filtering) are still applied
  # downstream by `Magus.SuperBrain.Extraction.Sanitizer`.
  defp extraction_schema do
    entity =
      Zoi.object(%{
        name: Zoi.string(),
        type: Zoi.string(),
        subtype: Zoi.union([Zoi.string(), Zoi.null()]) |> Zoi.optional(),
        confidence: Zoi.number()
      })

    edge =
      Zoi.object(%{
        subject_name: Zoi.string(),
        object_name: Zoi.string(),
        predicate: Zoi.string(),
        confidence: Zoi.number()
      })

    Zoi.object(%{
      entities: Zoi.array(entity),
      edges: Zoi.array(edge)
    })
  end

  defp build_usage(%ReqLLM.Response{} = response, model_name) do
    raw = ReqLLM.Response.usage(response) || %{}

    prompt = read_usage_field(raw, :prompt_tokens) || read_usage_field(raw, :input_tokens) || 0

    completion =
      read_usage_field(raw, :completion_tokens) || read_usage_field(raw, :output_tokens) || 0

    total =
      read_usage_field(raw, :total_tokens) ||
        prompt + completion

    cached = read_usage_field(raw, :cached_tokens) || 0
    reasoning = read_usage_field(raw, :reasoning_tokens)

    {input_cost, output_cost, total_cost, provider} = cost_for(model_name, prompt, completion)

    %Magus.SuperBrain.Usage{
      model_name: model_name,
      provider: provider,
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: total,
      cached_tokens: cached,
      reasoning_tokens: reasoning,
      input_cost: input_cost,
      output_cost: output_cost,
      total_cost: total_cost
    }
  end

  defp read_usage_field(raw, key) when is_atom(key) do
    Map.get(raw, key) || Map.get(raw, Atom.to_string(key))
  end

  defp cost_for(model_name, prompt_tokens, completion_tokens) do
    case Magus.Chat.get_model_by_name(model_name) do
      {:ok, %Magus.Chat.Model{} = model} ->
        input_per = model_pricing(model, :input)
        output_per = model_pricing(model, :output)

        input_cost = Decimal.mult(input_per, Decimal.new(prompt_tokens))
        output_cost = Decimal.mult(output_per, Decimal.new(completion_tokens))
        total_cost = Decimal.add(input_cost, output_cost)
        provider = model.api_provider && to_string(model.api_provider)
        {input_cost, output_cost, total_cost, provider}

      _ ->
        zero = Decimal.new("0")
        {zero, zero, zero, nil}
    end
  rescue
    _ ->
      zero = Decimal.new("0")
      {zero, zero, zero, nil}
  end

  # Per-token cost in dollars, derived from `input_cost_value` /
  # `output_cost_value` (numeric value in the unit indicated by
  # `*_cost_unit`). For `:per_million_tokens`, divide by 1_000_000.
  # Non-token units (per_image, per_second, etc.) are not applicable to
  # chat completion calls and return zero.
  defp model_pricing(model, :input),
    do: per_token_cost(model.input_cost_value, model.input_cost_unit)

  defp model_pricing(model, :output),
    do: per_token_cost(model.output_cost_value, model.output_cost_unit)

  defp per_token_cost(nil, _unit), do: Decimal.new("0")

  defp per_token_cost(%Decimal{} = value, :per_million_tokens) do
    Decimal.div(value, Decimal.new(1_000_000))
  end

  defp per_token_cost(_value, _unit), do: Decimal.new("0")
end
