defmodule Magus.SuperBrain.Tools.GetDossier do
  @moduledoc """
  Jido tool: everything known about one entity across all accessible sources.
  Groups the entity's claims (as subject and as object) into facts, referenced-by,
  and conflicts, each with citations and newest-first ordering. Falls back to the
  entity graph view when the entity has no claims yet.
  """

  use Jido.Action,
    name: "get_dossier",
    description: """
    Everything known about ONE entity across all your sources: grouped facts with
    citations, conflicts flagged, newest first. Use when the user asks "what do we
    know about X" or you need a consolidated view of a person, project, or concept.
    """,
    schema: [
      entity_name: [type: :string, required: true, doc: "The entity to build a dossier for"],
      entity_type: [type: {:or, [:string, nil]}, default: nil, doc: "Optional type disambiguator"],
      limit: [type: :integer, default: 20, doc: "Max claim groups"]
    ]

  require Ash.Query
  require Logger

  alias Magus.SuperBrain.{AccessibleGraphs, Claim, Dossier, Naming, Retrieval, Temporal}

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  def display_name, do: "Building dossier..."

  def summarize_output(%{facts: facts, conflicts: conflicts}) do
    "#{length(facts)} facts, #{length(conflicts)} conflicts"
  end

  def summarize_output(%{fallback: _}), do: "No claims yet; showing entity view"
  def summarize_output(_), do: "No results"

  @impl true
  def run(params, context) do
    name = get_param(params, :entity_name)
    user_id = Map.get(context, :user_id)

    cond do
      is_nil(user_id) -> {:ok, %{error: "Missing user_id in context"}}
      is_nil(name) or name == "" -> {:ok, %{error: "Missing entity_name"}}
      true -> build_dossier(name, user_id, params, context)
    end
  end

  defp build_dossier(name, user_id, params, context) do
    with {:ok, user} <- Magus.Accounts.get_user(user_id, authorize?: false) do
      key = Naming.key(name)
      graphs = accessible_graphs(user, context)

      {:ok, claims} =
        Claim
        |> Ash.Query.for_read(:for_entity_keys, %{keys: [key], graph_names: graphs})
        |> Ash.Query.load(:episode)
        |> Ash.read(authorize?: false)

      # `entity_type`, when supplied, disambiguates which same-named entity is
      # meant: keep only the claims where THIS entity (as subject or object)
      # carries the requested type. subject_type/object_type are stored as
      # strings on Claim and entity_type is a string, so `==` compares strings.
      # Filtering runs on the raw Claim structs (which carry subject_type /
      # object_type), before mapping to the reduced dossier-claim shape.
      filtered = filter_by_type(claims, key, get_param(params, :entity_type))

      if filtered == [] do
        fallback(name, user, context)
      else
        limit = get_param(params, :limit, 20)

        # Temporal resolution runs over the subject-side claims only: the
        # :for_entity_keys fetch is history-complete for THIS entity's
        # (subject, predicate) groups, but object-side groups belong to
        # other subjects whose sibling claims were not fetched, so resolving
        # them would yield false current verdicts. Object-side claims pass
        # through untagged (status defaults to :current in Dossier.build).
        now = DateTime.utc_now()
        {as_subject, as_object} = Enum.split_with(filtered, &(&1.subject_key == key))
        resolved = Temporal.resolve(as_subject, now: now)

        tagged =
          Enum.map(resolved.current, fn %{claim: c} -> {c, :current} end) ++
            Enum.map(resolved.historic, fn %{claim: c, reason: r} -> {c, r} end) ++
            Enum.map(as_object, fn c -> {c, :current} end)

        d =
          Dossier.build(
            key,
            Enum.map(tagged, fn {c, status} ->
              c |> to_dossier_claim() |> Map.put(:status, status)
            end)
          )

        # Cap the returned groups to `limit`. facts / referenced_by / history
        # are already ordered newest-first by Dossier.build, so this keeps the
        # most recent entries. `conflicts` is intentionally left uncapped: it
        # is the conflict summary and should surface every conflicting triple.
        d = %{
          d
          | facts: Enum.take(d.facts, limit),
            referenced_by: Enum.take(d.referenced_by, limit),
            history: Enum.take(d.history, limit)
        }

        {:ok, Map.put(d, :entity, name)}
      end
    else
      {:error, reason} ->
        Logger.warning("get_dossier: get_user failed: #{inspect(reason)}")
        {:ok, %{error: "Dossier unavailable"}}
    end
  end

  defp filter_by_type(claims, _key, nil), do: claims
  defp filter_by_type(claims, _key, ""), do: claims

  defp filter_by_type(claims, key, type) do
    Enum.filter(claims, fn c ->
      (c.subject_key == key and c.subject_type == type) or
        (c.object_key == key and c.object_type == type)
    end)
  end

  defp fallback(name, user, context) do
    case Retrieval.search(user,
           query: name,
           query_embedding: fallback_embedding(name),
           workspace_context: Map.get(context, :workspace_id),
           limit: 5
         ) do
      {:ok, %{entities: entities}} -> {:ok, %{fallback: entities, entity: name}}
      _ -> {:ok, %{fallback: [], entity: name}}
    end
  end

  defp fallback_embedding(name) do
    case Magus.SuperBrain.EmbeddingConfig.embedder().embed(name, []) do
      {:ok, %{embedding: e}} ->
        e

      {:ok, e} when is_list(e) ->
        e

      other ->
        Logger.warning("get_dossier: fallback embedding failed: #{inspect(other)}")
        []
    end
  end

  defp to_dossier_claim(c) do
    %{
      subject_key: c.subject_key,
      subject_name: c.subject_name,
      object_key: c.object_key,
      object_name: c.object_name,
      predicate: c.predicate,
      polarity: c.polarity,
      claim_text: c.claim_text,
      trust_tier: c.trust_tier,
      asserted_at: c.asserted_at
    }
  end

  defp accessible_graphs(user, context) do
    user
    |> AccessibleGraphs.for_actor(workspace_context: Map.get(context, :workspace_id))
    |> Enum.reject(&String.starts_with?(&1, "super:"))
  end
end
