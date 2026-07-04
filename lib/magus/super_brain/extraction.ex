defmodule Magus.SuperBrain.Extraction do
  @moduledoc """
  LLM-driven entity and claim extraction orchestrator.

  Pipeline:

    1. Build a system + user prompt via `Magus.SuperBrain.Extraction.Prompt`.
    2. Call the configured `Magus.SuperBrain.LLMClient` implementation.
    3. Parse the LLM's strict-JSON output.
    4. Sanitise entities and claims via `Magus.SuperBrain.Extraction.Sanitizer`
       (clipping, control-char stripping, confidence clamping, ontology
       coercion). Drops claims whose subject or object names are not in the
       sanitised entity set.
    5. Derive L1 `edges` from the sanitised claims (`claims_to_edges/1`) so
       the FalkorDB builders keep consuming the same edge shape unchanged.

  The LLM client is resolved at runtime from the application env so tests
  can bind a Mox mock without touching production code.
  """

  alias Magus.SuperBrain.Extraction.{Prompt, Sanitizer}

  require Logger

  @doc """
  Extracts entities and claims from `text`.

  Options:

    * `:model` - optional model string forwarded to the LLM client.
    * `:user_id` - optional user id; propagated through the return map so
      callers (e.g. the extraction worker) can attribute usage to a user
      when writing `MessageUsage` rows.

  Returns:

    * `{:ok, %{entities: [...], claims: [...], edges: [...], usage: %Magus.SuperBrain.Usage{}, user_id: id_or_nil}}`
      where `claims` are sanitized claim maps and `edges` are derived from
      those claims (one per claim).
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
          {:ok, payload |> Map.put(:usage, usage) |> Map.put(:user_id, user_id)}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_and_sanitize(raw) do
    with {:ok, payload} <- decode_json(raw),
         %{"entities" => raw_entities, "claims" => raw_claims} <- payload do
      entities =
        raw_entities
        |> Enum.map(&sanitize_entity_input/1)
        |> Enum.reject(&(&1 == :skip))

      entity_names = MapSet.new(entities, & &1.name)

      sanitized =
        raw_claims
        |> Enum.map(&Sanitizer.sanitize_claim/1)
        |> Enum.reject(&(&1 == :skip))

      claims =
        Enum.filter(sanitized, fn c ->
          MapSet.member?(entity_names, c.subject_name) and
            MapSet.member?(entity_names, c.object_name)
        end)

      # Observability: claims dropped because an endpoint was not an
      # extracted entity. Emitted from day one so sanitizer strictness is
      # measurable.
      Magus.SuperBrain.Telemetry.claims_dropped(length(sanitized) - length(claims))

      {:ok, %{entities: entities, claims: claims, edges: claims_to_edges(claims)}}
    else
      {:error, :invalid_json} = err -> err
      _ -> {:error, :unexpected_schema}
    end
  end

  @doc """
  Derives L1 `RELATES_TO` edge observations from claims: one per claim, using
  the claim's predicate as an atom (via the atom-safe classifier). The
  FalkorDB builders consume these unchanged; polarity stays on the claim,
  not the edge.
  """
  def claims_to_edges(claims) do
    Enum.map(claims, fn c ->
      %{
        subject_name: c.subject_name,
        object_name: c.object_name,
        predicate: predicate_atom(c.predicate),
        confidence: c.confidence
      }
    end)
  end

  defp predicate_atom(p) when is_binary(p) do
    case Magus.SuperBrain.Ontology.classify_predicate(p) do
      {:canonical, atom} -> atom
      {:freeform, atom} when is_atom(atom) -> atom
      _ -> :relates_to
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
