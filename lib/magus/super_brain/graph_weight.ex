defmodule Magus.SuperBrain.GraphWeight do
  @moduledoc """
  Per-graph weight configuration used by the retrieval ranker.

  The Super Brain ranks retrieval candidates by combining their similarity
  score with a graph-level weight. Default weights are hardcoded by graph
  name prefix (e.g. `brain:` -> 1.5, `memories:user:` -> 1.4). Users can
  override the default weight for specific graph patterns by creating rows
  with `scope: :user` and a `graph_pattern` (supports `*` wildcards).

  This resource is system-internal: it is consulted by the ranker via
  `weight_for/2` rather than by user-actor Ash queries, so no policies
  are defined.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.SuperBrain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table "super_brain_graph_weights"
    repo Magus.Repo
  end

  @defaults %{
    "brain:" => 1.5,
    "memories:user:" => 1.4,
    "memories:workspace:" => 1.3,
    "drafts:user:" => 1.0,
    "files:user:" => 1.0,
    "files:workspace:" => 1.0
  }

  actions do
    default_accept [:scope, :scope_id, :graph_pattern, :weight]
    defaults [:read, :create, :update, :destroy]
  end

  policies do
    # Iter1: system-internal only. weight_for/2 reads via authorize?: false.
    # External writes blocked until an admin UI ships in iter2.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end

    policy action_type(:read) do
      # Reads are gated at the call site (weight_for/2 uses authorize?: false
      # for internal lookups). Authenticated reads are fine but bring nothing
      # sensitive; allow them.
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :scope, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:global, :workspace, :user]]

    attribute :scope_id, :uuid, public?: true
    attribute :graph_pattern, :string, allow_nil?: false, public?: true
    attribute :weight, :float, allow_nil?: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc """
  Returns the weight for a given graph name and actor.

  Looks up user-scoped overrides first (any row matching the graph name via
  the row's `graph_pattern` glob). If none match, falls back to the default
  weight selected by the longest matching prefix in `@defaults`, or `1.0`
  if no default applies.
  """
  def weight_for(graph_name, actor) do
    user_id = actor.id

    user_overrides =
      case __MODULE__
           |> Ash.Query.filter(scope == :user and scope_id == ^user_id)
           |> Ash.read(authorize?: false) do
        {:ok, rows} -> rows
        {:error, _} -> []
      end

    user_override = Enum.find(user_overrides, fn gw -> matches?(graph_name, gw.graph_pattern) end)

    if user_override do
      user_override.weight
    else
      default_weight(graph_name)
    end
  end

  defp default_weight(graph_name) do
    Enum.find_value(@defaults, 1.0, fn {prefix, w} ->
      if String.starts_with?(graph_name, prefix), do: w, else: nil
    end)
  end

  defp matches?(graph_name, pattern) do
    escaped = pattern |> Regex.escape() |> String.replace("\\*", ".*")

    case Regex.compile("^" <> escaped <> "$") do
      {:ok, regex} -> Regex.match?(regex, graph_name)
      _ -> false
    end
  end
end
