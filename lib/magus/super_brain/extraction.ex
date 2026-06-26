defmodule Magus.SuperBrain.Extraction do
  @moduledoc """
  LLM-driven entity and edge extraction orchestrator.

  Pipeline:

    1. Build a system + user prompt via `Magus.SuperBrain.Extraction.Prompt`.
    2. Call the configured `Magus.SuperBrain.LLMClient` implementation.
    3. Parse the LLM's strict-JSON output.
    4. Sanitise entities and edges via `Magus.SuperBrain.Extraction.Sanitizer`
       (clipping, control-char stripping, confidence clamping, ontology
       coercion). Drops edges whose subject or object names are not in the
       sanitised entity set.

  The LLM client is resolved at runtime from the application env so tests
  can bind a Mox mock without touching production code.
  """

  alias Magus.SuperBrain.Extraction.{Prompt, Sanitizer}

  require Logger

  @doc """
  Extracts entities and edges from `text`.

  Options:

    * `:model` - optional model string forwarded to the LLM client.
    * `:user_id` - optional user id; propagated through the return map so
      callers (e.g. the extraction worker) can attribute usage to a user
      when writing `MessageUsage` rows.

  Returns:

    * `{:ok, %{entities: [...], edges: [...], usage: %Magus.SuperBrain.Usage{}, user_id: id_or_nil}}`
    * `{:error, :invalid_json}` - LLM output did not parse as JSON.
    * `{:error, :unexpected_schema}` - LLM JSON was missing expected keys.
    * `{:error, term()}` - propagated from the LLM client.
  """
  def extract(text, opts \\ []) when is_binary(text) do
    user_id = Keyword.get(opts, :user_id)
    %{system: sys, user: usr} = Prompt.build(text)

    messages = [
      %{role: "system", content: sys},
      %{role: "user", content: usr}
    ]

    case llm_client().complete(messages, model: opts[:model]) do
      {:ok, %{content: raw, usage: %Magus.SuperBrain.Usage{} = usage}} ->
        with {:ok, payload} <- parse_and_sanitize(raw) do
          maybe_emit_sparse_edges(payload, user_id)
          {:ok, payload |> Map.put(:usage, usage) |> Map.put(:user_id, user_id)}
        end

      {:error, _} = err ->
        err
    end
  end

  # iter5 Task 3.6: observability for hub-and-spoke extractions. The prompt
  # asks the LLM to aim for N/2 edges with a floor of 2 when N >= 3, but it
  # is honor-system: nothing in the pipeline currently rejects or re-prompts
  # on under-density. Emit a telemetry counter and Logger.info when a batch
  # falls below the floor so we can measure how often the LLM ignores the
  # guidance in real traffic. Logger level is :info, not :warning, because
  # sparse extractions are not errors (a one-line input is correctly
  # sparse); we only want a signal to drive prompt iteration.
  defp maybe_emit_sparse_edges(%{entities: entities, edges: edges}, user_id)
       when is_list(entities) and is_list(edges) do
    n = length(entities)
    e = length(edges)

    if n >= 3 and e < 2 do
      :telemetry.execute(
        [:super_brain, :extraction, :sparse_edges],
        %{count: 1},
        %{entity_count: n, edge_count: e, user_id: user_id}
      )

      Logger.info(
        "super_brain: sparse-edge extraction (entities=#{n} edges=#{e}); " <>
          "below N/2 target and the floor of 2 for N>=3"
      )
    end

    :ok
  end

  defp maybe_emit_sparse_edges(_payload, _user_id), do: :ok

  defp parse_and_sanitize(raw) do
    with {:ok, payload} <- decode_json(raw),
         %{"entities" => raw_entities, "edges" => raw_edges} <- payload do
      entities =
        raw_entities
        |> Enum.map(&sanitize_entity_input/1)
        |> Enum.reject(&(&1 == :skip))

      entity_names = MapSet.new(entities, & &1.name)

      edges =
        raw_edges
        |> Enum.map(&sanitize_edge_input/1)
        |> Enum.reject(&(&1 == :skip))
        |> Enum.filter(fn e ->
          MapSet.member?(entity_names, e.subject_name) and
            MapSet.member?(entity_names, e.object_name)
        end)

      {:ok, %{entities: entities, edges: edges}}
    else
      {:error, :invalid_json} = err -> err
      _ -> {:error, :unexpected_schema}
    end
  end

  # Models frequently wrap the JSON object in markdown fences (```json … ```)
  # or surround it with prose ("Here is the JSON: { … }"). Strip fences and
  # slice to the outermost `{ … }` before decoding so a slightly-chatty
  # response still parses instead of discarding the whole extraction as
  # `:invalid_json`.
  defp decode_json(raw) when is_binary(raw) do
    cleaned = raw |> strip_code_fences() |> slice_to_outer_object()

    case Jason.decode(cleaned) do
      {:ok, payload} -> {:ok, payload}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp decode_json(_), do: {:error, :invalid_json}

  defp strip_code_fences(s) do
    s = String.trim(s)

    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/si, s, capture: :all_but_first) do
      [inner] -> String.trim(inner)
      _ -> s
    end
  end

  defp slice_to_outer_object(s) do
    with {start, _} <- :binary.match(s, "{"),
         [_ | _] = closes <- :binary.matches(s, "}") do
      {stop, _} = List.last(closes)
      if stop >= start, do: binary_part(s, start, stop - start + 1), else: s
    else
      _ -> s
    end
  end

  defp sanitize_entity_input(%{"name" => n, "type" => t, "confidence" => c} = e) do
    Sanitizer.sanitize_entity(%{
      name: n,
      type: safe_atom(t),
      subtype: Map.get(e, "subtype"),
      confidence: c
    })
  end

  defp sanitize_entity_input(_malformed), do: :skip

  defp sanitize_edge_input(%{
         "subject_name" => s,
         "object_name" => o,
         "predicate" => p,
         "confidence" => c
       }) do
    Sanitizer.sanitize_edge(%{
      subject_name: s,
      object_name: o,
      predicate: p,
      confidence: c
    })
  end

  defp sanitize_edge_input(_malformed), do: :skip

  # The LLM emits type strings; only convert to atoms when the atom is
  # already known. Unknown strings degrade to :concept and the sanitizer's
  # normalize_type/1 keeps it there. This avoids atom-exhaustion DoS from
  # an adversarial or verbose LLM (atoms are never garbage collected).
  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> :concept
  end

  defp safe_atom(a) when is_atom(a), do: a

  defp llm_client, do: Application.fetch_env!(:magus, :super_brain_llm_client)
end
