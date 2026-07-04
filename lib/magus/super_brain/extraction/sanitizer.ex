defmodule Magus.SuperBrain.Extraction.Sanitizer do
  @moduledoc """
  Defensive sanitizer for LLM-extracted entities and edges.

  The extraction prompt may produce names, types and predicates that are
  untrusted strings. This module:

    * clips overlong strings (`name` to 200, `predicate` to 60 chars),
    * strips Unicode `Cc` control characters (NUL, newlines, etc.),
    * coerces `confidence` into the `[0.0, 1.0]` interval,
    * normalises entity types to one of `Magus.SuperBrain.Ontology`'s seed
      types, falling back to `:concept`,
    * normalises edge predicates to snake_case atoms, returning `:skip`
      when subject or object are empty after trimming.

  ## Atom safety

  Atoms in the BEAM are never garbage-collected. A verbose or adversarial
  LLM could mint unbounded atoms via `String.to_atom/1`, exhausting the
  atom table and crashing the node. Following the pattern established in
  `Magus.SuperBrain.Ontology`, this module uses `String.to_existing_atom/1`
  with a rescue to a safe fallback:

    * unknown entity-type strings degrade to `:concept`,
    * unknown predicate strings degrade to `:relates_to` (the canonical
      catch-all predicate).

  Callers that need to introduce new predicates or types should do so at
  explicit, controlled call sites (for example a curated ontology
  promotion pass), not implicitly during sanitisation.
  """

  alias Magus.SuperBrain.Ontology
  alias Magus.SuperBrain.Telemetry, as: SBTelemetry

  @max_name_length 200
  @max_predicate_length 60
  @max_claim_text 500

  @doc """
  Sanitises an extracted entity map.

  Required keys: `:name`, `:type`, `:confidence`. Optional `:subtype` is
  passed through unchanged.
  """
  def sanitize_entity(%{name: name, type: type, confidence: conf} = entity) do
    %{
      name: name |> strip_control() |> String.trim() |> clip(@max_name_length),
      type: normalize_type(type),
      subtype: Map.get(entity, :subtype),
      confidence: clamp(conf, 0.0, 1.0)
    }
  end

  @doc """
  Sanitises an extracted edge map.

  Returns `:skip` when subject or object names are empty after stripping
  control characters and trimming whitespace.
  """
  def sanitize_edge(%{
        subject_name: sub,
        object_name: obj,
        predicate: pred,
        confidence: conf
      }) do
    sub = sub |> strip_control() |> String.trim()
    obj = obj |> strip_control() |> String.trim()

    if sub == "" or obj == "" do
      :skip
    else
      %{
        subject_name: clip(sub, @max_name_length),
        object_name: clip(obj, @max_name_length),
        predicate: normalize_predicate(pred),
        confidence: clamp(conf, 0.0, 1.0)
      }
    end
  end

  @doc """
  Sanitises an extracted claim map. Returns `:skip` when subject, object, or
  claim text is empty after trimming. Predicate is normalised like edges;
  polarity is whitelisted (default `:affirms`); dates are parsed as ISO 8601
  with graceful nil.
  """
  def sanitize_claim(claim) do
    sub = claim |> fetch(:subject_name) |> to_string() |> strip_control() |> String.trim()
    obj = claim |> fetch(:object_name) |> to_string() |> strip_control() |> String.trim()
    text = claim |> fetch(:claim_text) |> to_string() |> strip_control() |> String.trim()

    if sub == "" or obj == "" or text == "" do
      :skip
    else
      %{
        subject_name: clip(sub, @max_name_length),
        object_name: clip(obj, @max_name_length),
        predicate: predicate_string(fetch(claim, :predicate)),
        polarity: polarity(fetch(claim, :polarity)),
        claim_text: clip(text, @max_claim_text),
        confidence: claim |> fetch(:confidence) |> number_or(0.0) |> clamp(0.0, 1.0),
        valid_from: parse_date(fetch(claim, :valid_from)),
        valid_to: parse_date(fetch(claim, :valid_to))
      }
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # Reuse edge predicate normalization, but keep the result a STRING (claims
  # store predicate as text) instead of an atom.
  defp predicate_string(p) do
    case normalize_predicate(p) do
      atom when is_atom(atom) -> Atom.to_string(atom)
      other -> to_string(other)
    end
  end

  defp polarity(p) when p in [:negates, "negates"], do: :negates
  defp polarity(_), do: :affirms

  defp number_or(v, _default) when is_number(v), do: v
  defp number_or(_v, default), do: default

  defp parse_date(nil), do: nil

  defp parse_date(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp normalize_type(t) when is_atom(t) do
    if Ontology.valid_entity_type?(t) do
      t
    else
      SBTelemetry.sanitizer_type_fallback(Atom.to_string(t))
      :concept
    end
  end

  defp normalize_type(t) when is_binary(t) do
    atom = String.to_existing_atom(t)

    case normalize_type(atom) do
      :concept when atom != :concept ->
        # `normalize_type/1` already emitted the fallback via the atom
        # branch above; do not double-count.
        :concept

      other ->
        other
    end
  rescue
    ArgumentError ->
      SBTelemetry.sanitizer_type_fallback(t)
      :concept
  end

  defp normalize_type(other) do
    SBTelemetry.sanitizer_type_fallback(inspect(other))
    :concept
  end

  defp normalize_predicate(p) when is_atom(p), do: p

  defp normalize_predicate(p) when is_binary(p) do
    cleaned =
      p
      |> strip_control()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, "_")
      |> String.trim("_")
      |> clip(@max_predicate_length)

    # Explicit empty-string clause: `String.to_existing_atom("")` happens
    # to succeed (the `:""` atom is preloaded by the BEAM) and would let
    # an empty predicate reach the graph as the `:""` atom. Catch that
    # here and fall through to the canonical catch-all instead.
    if cleaned == "" do
      SBTelemetry.sanitizer_predicate_fallback(p)
      :relates_to
    else
      String.to_existing_atom(cleaned)
    end
  rescue
    ArgumentError ->
      SBTelemetry.sanitizer_predicate_fallback(p)
      :relates_to
  end

  defp normalize_predicate(other) do
    SBTelemetry.sanitizer_predicate_fallback(inspect(other))
    :relates_to
  end

  defp strip_control(s) when is_binary(s) do
    String.replace(s, ~r/\p{Cc}/u, "")
  end

  defp clip(s, n) when is_binary(s) do
    if String.length(s) > n, do: String.slice(s, 0, n), else: s
  end

  defp clamp(v, lo, hi) when is_number(v), do: max(lo, min(hi, v))
end
