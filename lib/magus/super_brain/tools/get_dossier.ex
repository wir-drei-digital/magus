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

  alias Magus.SuperBrain.{AccessibleGraphs, Claim, Dossier, Naming, Retrieval}

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

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
      true -> build_dossier(name, user_id, context)
    end
  end

  defp build_dossier(name, user_id, context) do
    with {:ok, user} <- Magus.Accounts.get_user(user_id, authorize?: false) do
      key = Naming.key(name)
      graphs = accessible_graphs(user, context)

      {:ok, claims} =
        Claim
        |> Ash.Query.for_read(:for_entity_keys, %{keys: [key], graph_names: graphs})
        |> Ash.Query.load(:episode)
        |> Ash.read(authorize?: false)

      if claims == [] do
        fallback(name, user, context)
      else
        d = Dossier.build(key, Enum.map(claims, &to_dossier_claim/1))
        {:ok, Map.put(d, :entity, name)}
      end
    else
      _ -> {:ok, %{error: "Dossier unavailable"}}
    end
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
      {:ok, %{embedding: e}} -> e
      {:ok, e} when is_list(e) -> e
      _ -> []
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
